-module(lhttpc_dns_tests).

-export([ printrec/1 ]).

-include_lib("eunit/include/eunit.hrl").

lhttpc_dns_disabled_test () ->
  %% Verify that if lhttpc_dns is not enabled that lhttpc_dns:lookup
  %% returns the original hostname.
  {inorder,
   {setup, fun lhttpc_dns:destroy_table/0,
    [ ?_assertEqual("example.com", lhttpc_dns:lookup("example.com"))
    ]}
  }.

lhttpc_dns_enabled_test_ () ->
  {inorder,
   {setup, fun lhttpc_dns:create_table/0, fun (_) -> lhttpc_dns:destroy_table() end,
    [ ?_test(test_lookup_uncached())
    , ?_test(test_lookup())
    ]}
  }.

test_lookup_uncached () ->
  ?assertMatch({[ {{127, 0, 0, 1}, _} ], _},
               lhttpc_dns:lookup_uncached(localhost)),
  ?assertMatch({[ {{127, 0, 0, 1}, _} ], _},
               lhttpc_dns:lookup_uncached("localhost")),
  ?assertMatch({undefined, _},
               lhttpc_dns:lookup_uncached("not-a-real-hostname.com")),
  ?assertMatch({[ {{93, 184, 216, 119}, _} ], _},
               lhttpc_dns:lookup_uncached("93.184.216.119")),
  ok.

-define(LOCALHOST, {127, 0, 0, 1}).
-define(MULTI1, {2, 0, 0, 0}).
-define(MULTI2, {3, 0, 0, 0}).
-define(SINGLE, {4, 0, 0, 0}).
-define(DYNAMIC(N), {5, 0, 0, N rem 8}).

test_lookup () ->
  lhttpc_dns:reset_table(),
  erlang:put(dns_lookup, 0),
  erlang:put(dns_random, 0),
  erlang:put(dns_ts, 0),

  MonotonicTimeFun = fun () -> erlang:convert_time_unit(erlang:get(dns_ts), seconds, native) end,
  LookupFun = fun (IPs, TTL) ->
               TTLTS = MonotonicTimeFun() + erlang:convert_time_unit(TTL, second, native),
               {[ {IP, TTLTS} || IP <- IPs ], TTL}
           end,

  meck:new(lhttpc_dns, [ passthrough ]),
  meck:expect(lhttpc_dns, monotonic_time, MonotonicTimeFun),
  meck:expect(lhttpc_dns, lookup_uncached,
              fun(Host) ->
                  %% io:format(standard_error, "host: ~p~n", [ Host ]),
                  case erlang:get(dns_lookup) of
                    dns_lookup_fail   -> erlang:put(dns_lookup, 0),
                                         {undefined, 1};
                    N ->
                      case Host of
                        "localhost"   -> LookupFun([ ?LOCALHOST ], 3600);
                        "single.com"  -> LookupFun([ ?SINGLE ], 1800);
                        "multi.com"   -> LookupFun([ ?MULTI1, ?MULTI2 ], 300);
                        "dynamic.com" -> erlang:put(dns_lookup, N + 1),
                                         LookupFun([ ?DYNAMIC(N) ], 60);
                        _             -> {undefined, 1}
                      end
                  end
              end),

  meck:new(rand, [ passthrough, unstick ]),
  meck:expect(rand, uniform, fun (N) -> I = erlang:get(dns_random), erlang:put(dns_random, I + 1), I rem N + 1 end),

  %% Verify that our function has been successfully mecked.
  ?assertMatch({[ {?LOCALHOST, _} ], 3600}, lhttpc_dns:lookup_uncached("localhost")),

  %% Verify that IP address caching is working.
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  lhttpc_dns:print_cache("single.com"),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 60),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(2, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  lhttpc_dns:print_cache("single.com"),
  erlang:put(dns_ts, 70),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  lhttpc_dns:print_cache("single.com"),
  ?assertEqual(2, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 2400),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  lhttpc_dns:print_cache("single.com"),
  ?assertEqual(3, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),

  %% When a hostname has multiple IP addresses, a random one is returned.
  erlang:put(dns_ts, 3600),
  erlang:put(dns_random, 0),
  ?assertEqual(?MULTI1, lhttpc_dns:lookup("multi.com")),
  ?assertEqual(?MULTI2, lhttpc_dns:lookup("multi.com")),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "multi.com" ])),
  erlang:put(dns_ts, 3630),
  ?assertEqual(?MULTI1, lhttpc_dns:lookup("multi.com")),
  ?assertEqual(2, meck:num_calls(lhttpc_dns, lookup_uncached, [ "multi.com" ])),
  erlang:put(dns_ts, 3720),
  ?assertEqual(?MULTI2, lhttpc_dns:lookup("multi.com")),
  ?assertEqual(2, meck:num_calls(lhttpc_dns, lookup_uncached, [ "multi.com" ])),

  %% When a DNS lookup for a cached hostname fails, the old value is cached
  %% for an additional MIN_CACHE_SECONDS.
  erlang:put(dns_ts, 7200),
  erlang:put(dns_lookup, dns_lookup_fail),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(4, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 7201),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(4, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 7600),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(5, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 7601),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(5, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 8000),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(5, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 10800),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(6, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_lookup, 0),

  %% Error lookups are only cached for ERROR_CACHE_SECONDS.
  ?assertEqual(undefined, lhttpc_dns:lookup("noaddr.com")),
  ?assertEqual(undefined, lhttpc_dns:lookup("noaddr.com")),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "noaddr.com" ])),
  erlang:put(dns_ts, 10802),
  ?assertEqual(undefined, lhttpc_dns:lookup("noaddr.com")),
  ?assertEqual(2, meck:num_calls(lhttpc_dns, lookup_uncached, [ "noaddr.com" ])),

  %% Dynamic lookups.
  %% These tests are unfortunately tied to the implementation details more
  %% than I would like and thus are much more brittle than I would like.
  erlang:put(dns_lookup, 0),
  erlang:put(dns_ts, 12000),
  ?assertEqual({5, 0, 0, 0}, lhttpc_dns:lookup("dynamic.com")),
  %% If the next lookup is less than the TTL lhttpc_dns doesn't realize that
  %% the address is dynamic and so it doesn't do another query.
  erlang:put(dns_ts, 12001), % printrec("dynamic.com"),
  ?assertEqual({5, 0, 0, 0}, lhttpc_dns:lookup("dynamic.com")),
  %% This is the second lookup after seeing the hostname for the first time,
  %% so there is a short TTL.
  erlang:put(dns_ts, 12005), % printrec("dynamic.com"),
  ?assertEqual([ {5, 0, 0, 0}, {5, 0, 0, 1} ], repeat_lookup("dynamic.com", 8)),
  erlang:put(dns_ts, 12006),
  ?assertEqual([ {5, 0, 0, 0}, {5, 0, 0, 1} ], repeat_lookup("dynamic.com", 8)),
  erlang:put(dns_ts, 12010), % printrec("dynamic.com"),
  ?assertEqual([ {5, 0, 0, 0}, {5, 0, 0, 1}, {5, 0, 0, 2} ], repeat_lookup("dynamic.com", 8)),
  erlang:put(dns_ts, 12055), % printrec("dynamic.com"),
  ?assertEqual([ {5, 0, 0, 0}, {5, 0, 0, 1}, {5, 0, 0, 2}, {5, 0, 0, 3} ], repeat_lookup("dynamic.com", 8)),
  erlang:put(dns_ts, 12060), % printrec("dynamic.com"),
  ?assertEqual([ {5, 0, 0, 1}, {5, 0, 0, 2}, {5, 0, 0, 3}, {5, 0, 0, 4} ], repeat_lookup("dynamic.com", 8)),
  erlang:put(dns_ts, 12070), % printrec("dynamic.com"),
  ?assertEqual([ {5, 0, 0, 3}, {5, 0, 0, 4}, {5, 0, 0, 5} ], repeat_lookup("dynamic.com", 8)),

  meck:unload(rand),
  meck:unload(lhttpc_dns).


%% A helper function for testing dynamic lookups.
repeat_lookup (Host, N) ->
  lists:usort(repeat(N, fun () -> lhttpc_dns:lookup(Host) end, [])).

repeat (0, _Fun, Acc) -> Acc;
repeat (N, Fun, Acc) ->
  repeat(N - 1, Fun, [ Fun() | Acc ]).

printrec (Host) ->
  lhttpc_dns:lookup(Host),
  io:format(user, "dynamic ~p\n  ~p\n", [ erlang:get(dns_ts), ets:lookup(lhttpc_dns, Host) ]).
