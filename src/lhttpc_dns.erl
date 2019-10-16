-module(lhttpc_dns).

-export([ init/1
        , create_table/0
        , check_table/0
        , destroy_table/0
        , reset_table/0
        , lookup/1
        , lookup_uncached/1
        , monotonic_time/0
        , expire_dynamic/1
        , print_cache/0
        , print_cache/1
        , print_tcpdump_hosts/1
        ]).


%% -include_lib("kernel/include/inet.hrl").


-type native_time() :: integer().
-type ttl() :: pos_integer().

-type ip_entry () :: {inet:ip_address(), native_time() | 'infinity'}.
%% Tuple of any length greater than 1 is OK, but 2 is enough to satisfy dialyzer.
-type ip_addrs () :: {ip_entry()} | {ip_entry(), ip_entry()}.

-record(dns_stats,
        { success_count = 0 :: non_neg_integer()
        , failure_count = 0 :: non_neg_integer()
        , failures_since_last_success_count = 0 :: non_neg_integer()
        , success_time :: native_time() | 'undefined'
        }).

-type dns_stats() :: #dns_stats{}.

-record(dns_rec,
        { hostname :: inet:hostname()
        , ip_addrs :: ip_addrs()            % list_to_tuple(list(ip_entry())).
        , expiration_time :: native_time()
        , dynamic_count = 0 :: non_neg_integer()
        , dynamic_pid :: pid() | 'undefined'
        , stats = #dns_stats{} :: dns_stats()
        }).

-define(DNS_DYNAMIC, 0).
-define(DNS_STATIC, 1).
-type dns_type() :: ?DNS_DYNAMIC | ?DNS_STATIC.


init (_Args) ->
  create_table().

choose_addr (IPAddrs) when is_tuple(IPAddrs) ->
  %% IPAddrs is a tuple each element of which is an ip_entry().
  %% We should round-robin through the IP addresses, but for now we
  %% just choose a random one.
  case size(IPAddrs) of
    0    -> undefined;
    1    -> element(1, element(1, IPAddrs));
    Size -> element(1, element(rand:uniform(Size), IPAddrs))
  end;
choose_addr(undefined) -> undefined.


monotonic_time() ->
  %% We wrap erlang:monotonic_time so that the unit tests can mock it.
  erlang:monotonic_time().


-define(ERROR_CACHE_SECONDS, 1).
-define(SUCCESS_CACHE_EXTRA_SECONDS, 2).
-define(MAX_CACHE_SECONDS, 3600).
-define(MIN_CACHE_SECONDS, 30).
-define(DYNAMIC_REQUERY_SECONDS, 4).
-define(DYNAMIC_REQUERY_COUNT, 12).
-define(MAX_CACHE_SIZE, 10000).


-define(TTL_TO_TS(TTL, Now), Now + erlang:convert_time_unit(TTL, seconds, native)).
-define(TS_TO_TTL(TS, Now), if is_integer(TS) -> erlang:convert_time_unit(TS - Now, native, seconds); true -> TS end).

-spec lookup(inet:hostname()) -> tuple() | 'undefined' | inet:hostname().
lookup (Host) ->
  {WantRefresh, CachedIPAddrs, Now, CachedStats} =
    try ets:lookup(?MODULE, Host) of
      [] ->                                             % Not in cache.
        {true, undefined, lhttpc_dns:monotonic_time(), undefined};
      [ #dns_rec{ip_addrs=IPAddrs0, expiration_time=ExpirationTime, stats=CachedStats0} ] -> % Cached, maybe stale.
        Now0 = lhttpc_dns:monotonic_time(),
        {Now0 >= ExpirationTime, IPAddrs0, Now0, CachedStats0}
    catch
      error:badarg ->
        {fallback, undefined, undefined, undefined}
    end,

  case WantRefresh of
    fallback ->
      %% Caching is not enabled.  Return original Host; gen_tcp will resolve it.
      Host;
    false ->
      %% Cached lookup succeeded
      choose_addr(CachedIPAddrs);
    true ->
      %% Cached lookup failed.  Perform lookup and cache results.
      case lhttpc_dns:lookup_uncached(Host) of
        {undefined, FailureTTL} ->
          %% If the lookup fails but we have a stale cached result, keep it.
          case CachedIPAddrs of
            undefined -> IPAddrs = undefined,
                         RefreshTS = ?TTL_TO_TS(FailureTTL, Now);
            _         -> IPAddrs = CachedIPAddrs,
                         RefreshTS = ?TTL_TO_TS(?MIN_CACHE_SECONDS, Now)
          end,
          DNSType = ?DNS_STATIC,
          Stats = count_failure(CachedStats);
        SuccessLookup ->
          {IPAddrs, DNSType} = merge_addrs(SuccessLookup, CachedIPAddrs, Now),
          RefreshTS = min_ttl_ts(IPAddrs, Now),
          Stats = count_success(CachedStats, Now)
      end,
      ets_insert_bounded(?MODULE, #dns_rec{hostname = Host, ip_addrs = IPAddrs,
                                           expiration_time = RefreshTS,
                                           stats = Stats}),
      DNSType =:= ?DNS_DYNAMIC andalso
        spawn(fun () -> update_dynamic(Host) end),
      choose_addr(IPAddrs)
  end.


-spec lookup_uncached(Host::inet:hostname()) -> {list(ip_entry())|'undefined', ttl()}.
lookup_uncached (Host) ->
  case inet:parse_address(Host) of
    {ok, IPAddr} ->
      %% If Host looks like an IP address already, just return it.
      {[ {IPAddr, 'infinity'} ], ?MAX_CACHE_SECONDS};
    _ ->
      %% Otherwise do a DNS lookup for the hostname.
      Now = lhttpc_dns:monotonic_time(),
      case inet_res:resolve(Host, in, a) of
        {ok, DNSRec} ->
          Answers = inet_dns:msg(DNSRec, anlist),
          {IPAddrs, TTL} =
            lists:foldl(
              fun (Answer, {IPAddrAcc, MinTTL}) ->
                  case inet_dns:rr(Answer, [ type, data, ttl ]) of
                    [ a, IPAddr, TTL ] ->
                      %% Cache a successful lookup for an additional
                      %% 2 seconds, to avoid refetching an entry
                      %% from the local DNS resolver right before it
                      %% refreshes its own cache.
                      TTLAdjusted = max(TTL + ?SUCCESS_CACHE_EXTRA_SECONDS, ?MIN_CACHE_SECONDS),
                      TTLTS = Now + erlang:convert_time_unit(TTLAdjusted, seconds, native),
                      {[ {IPAddr, TTLTS} | IPAddrAcc ], min(MinTTL, TTLAdjusted)};
                    _ ->
                      %% Ignore type=cname records in the answers.
                      {IPAddrAcc, MinTTL}
                  end
              end, {[], ?MAX_CACHE_SECONDS}, Answers),
          case IPAddrs of
            [] -> %% Answer was empty or contained no A records.  Treat it like a failure.
                  {undefined, ?ERROR_CACHE_SECONDS};
            _  -> {IPAddrs, max(TTL, ?MIN_CACHE_SECONDS)}
          end;
        _Error ->
          %% Cache an error lookup for one second.
          {undefined, ?ERROR_CACHE_SECONDS}
      end
  end.


-spec merge_addrs({list(ip_entry()), ttl()}, ip_addrs() | 'undefined', native_time()) -> {CachedOut::ip_addrs(), dns_type()}.
%% Merges a set of new DNS entries in `AddrsIn' into the cached DNS entries in
%% `CachedIn' and drops expired entries to produce `CachedOut'.
merge_addrs ({AddrsIn, _TTLIn}, CachedIn, Now) ->
  AddrsInMap = maps:from_list(AddrsIn),
  {AddrsOutMap, DNSType} =
    case CachedIn of
      undefined ->
        %% There are no cached addresses because this is the first call.  Use
        %% a short TTL.
        {AddrsInMap, ?DNS_DYNAMIC};
      _ ->
        %% Copy unexpired entries from the old cache into the new cache.  If
        %% we have any carryovers, that's an indication that the DNS lookup is
        %% giving us a subset of a larger set of IP addresses; in that case,
        %% use a short TTL.
        lists:foldl(
          fun ({CachedAddr, CachedTS}, Acc={AddrsAcc, DNSTypeAcc}) ->
              case maps:get(CachedAddr, AddrsAcc, undefined) of
                undefined ->
                  %% The cached entry was not found in the new address list.
                  %% Keep it if it isn't too old.  Use a short TTL.  CachedTS
                  %% may be 'infinity', which compares greater than any
                  %% integer.
                  case CachedTS > Now of
                    true        -> {maps:put(CachedAddr, CachedTS, AddrsAcc), ?DNS_DYNAMIC};
                    false       -> {AddrsAcc, ?DNS_DYNAMIC}
                  end;
                NewTS ->
                  %% The cached entry was found in the new address list.  Use
                  %% the greater of the cached TTL and the new TTL for the
                  %% entry's TTL.
                  case CachedTS > NewTS of
                    true        -> {maps:put(CachedAddr, CachedTS, AddrsAcc), DNSTypeAcc};
                    false       -> Acc
                  end
              end
          end, {AddrsInMap, ?DNS_STATIC}, tuple_to_list(CachedIn))
    end,
  AddrsOut = maps:to_list(AddrsOutMap),

  {list_to_tuple(AddrsOut), DNSType}.

-spec min_ttl_ts(ip_addrs(), integer()) -> integer().
min_ttl_ts (IPAddrs, Now) ->
  AddrsList = tuple_to_list(IPAddrs),
  max(min_ttl_ts_helper(AddrsList, ?TTL_TO_TS(?MAX_CACHE_SECONDS, Now)),
      ?TTL_TO_TS(?DYNAMIC_REQUERY_SECONDS, Now)).

-spec min_ttl_ts_helper(list(ip_entry()), integer()) -> integer().
min_ttl_ts_helper ([ {_, infinity} | Rest ], MinTTL) -> min_ttl_ts_helper(Rest, MinTTL);
min_ttl_ts_helper ([ {_, TTL} | Rest ], MinTTL) -> min_ttl_ts_helper(Rest, min(TTL, MinTTL));
min_ttl_ts_helper ([], MinTTL) -> MinTTL.


update_dynamic (Host) ->
  Now = lhttpc_dns:monotonic_time(),
  case ets:lookup(?MODULE, Host) of
    [] ->
      CachedIPAddrs = undefined,
      CachedDynamicCount = 1,
      CachedStats = #dns_stats{};
    [ #dns_rec{ip_addrs=CachedIPAddrs, dynamic_count=CachedDynamicCount, stats=CachedStats} ] ->
      ok
  end,
  {IPAddrs, DNSType, Stats} =
    lists:foldl(
      fun (_I, {AddrsAcc, DNSTypeAcc, StatsAcc}) ->
          case lhttpc_dns:lookup_uncached(Host) of
            {undefined, _} -> {AddrsAcc, DNSTypeAcc, count_failure(StatsAcc)};
            SuccessLookup  -> {AddrsX, DNSTypeX} = merge_addrs(SuccessLookup, AddrsAcc, Now),
                              {AddrsX, min(DNSTypeX, DNSTypeAcc), count_success(StatsAcc, Now)}
          end
      end, {CachedIPAddrs, ?DNS_STATIC, CachedStats}, lists:seq(1, ?DYNAMIC_REQUERY_COUNT)),
  DynamicCountOut = if DNSType =:= ?DNS_DYNAMIC -> ?DYNAMIC_REQUERY_COUNT; true -> max(CachedDynamicCount - 1, 0) end,
  RefreshTS = min_ttl_ts(IPAddrs, Now),
  ets_insert_bounded(?MODULE, #dns_rec{hostname = Host, ip_addrs = IPAddrs,
                                       expiration_time = RefreshTS,
                                       dynamic_count = DynamicCountOut,
                                       dynamic_pid = case DynamicCountOut of 0 -> undefined; _ -> self() end,
                                       stats = Stats}),
  DynamicCountOut > 0 andalso
    begin
      receive expire_timer -> ok after ?TS_TO_TTL(RefreshTS, Now) * 1000 -> ok end,
      update_dynamic(Host)
    end.


%% Prematurely end the update_dynamic wait.  This is used by the tests.
expire_dynamic (Host) ->
  case ets:lookup(?MODULE, Host) of
    [ #dns_rec{dynamic_pid=Pid} ] -> Pid ! expire_timer;
    _                             -> ok
  end.


-spec ets_insert_bounded(Tab::ets:tab(), Entry::term()) -> 'true'.
%% Insert the row `Entry' into the ETS table `Tab'.  Prevent the
%% unbounded growth of the ETS table by clearing it if it grows to
%% more than ?MAX_CACHE_SIZE entries.
ets_insert_bounded(Tab, Entry) ->
  case ets:info(Tab, size) of
    N when N >= ?MAX_CACHE_SIZE -> error_logger:warning_msg("lhttpc_dns cache full; resetting\n"),
                                   ets:delete_all_objects(Tab);
    _                           -> ok
  end,
  ets:insert(Tab, Entry).


%% Prints the contents of the DNS cache in a human readable format.
print_cache () ->
  Now = lhttpc_dns:monotonic_time(),
  lists:foreach(fun (Entry) -> print_cache_entry(Entry, Now) end, ets:tab2list(?MODULE)).

%% Prints the DNS cache entry for `Hostname' in a human readable format.
print_cache (Hostname) ->
  Now = lhttpc_dns:monotonic_time(),
  case ets:lookup(?MODULE, Hostname) of
    [Entry=#dns_rec{}] -> print_cache_entry(Entry, Now);
    _                  -> ok
  end.

print_cache_entry (#dns_rec{hostname=Hostname, ip_addrs=IPAddrs, expiration_time=ExpirationTime, stats=Stats}, Now) ->
  IPAddrsIOList = [ io_lib:format("  ~s ~p\n", [ inet:ntoa(IPAddr), ?TS_TO_TTL(TS, Now) ]) || {IPAddr, TS} <- tuple_to_list(IPAddrs) ],
  io:format("~s ttl: ~p sec (~p)\n~s  successes: ~p; failures: ~p; failures_since_last_success: ~p; success_time: ~p sec_ago\n",
            [ Hostname, ?TS_TO_TTL(ExpirationTime, Now), ExpirationTime - Now
            , IPAddrsIOList
            , Stats#dns_stats.success_count, Stats#dns_stats.failure_count, Stats#dns_stats.failures_since_last_success_count
            , ?TS_TO_TTL(Now, Stats#dns_stats.success_time)
            ]).


%% Prints the contents of the DNS cache in the tcpdump "host" expression.
%%
%% This is useful when lhttpc is using a larger set of IP addresses than are
%% returned by a single DNS lookup.
print_tcpdump_hosts (Hostname) ->
  case ets:lookup(?MODULE, Hostname) of
    [#dns_rec{ip_addrs=IPAddrs}] ->
      io:format("host ( ~s )\n", [ lists:join(" or ", [ inet:ntoa(IPAddr) || {IPAddr, _} <- tuple_to_list(IPAddrs) ]) ]);
    _ -> ok
  end.


-spec count_success(Stats::dns_stats()|'undefined', Now::integer()) -> dns_stats().
count_success (Stats=#dns_stats{success_count=SuccessCount}, Now) ->
  Stats#dns_stats{success_count = SuccessCount + 1, failures_since_last_success_count = 0, success_time = Now};
count_success (undefined, Now) ->
  #dns_stats{success_count = 1, success_time = Now}.


-spec count_failure(Stats::dns_stats()|'undefined') -> dns_stats().
count_failure (Stats=#dns_stats{failure_count=FailureCount, failures_since_last_success_count=FailuresSinceLastSuccessCount}) ->
  Stats#dns_stats{failure_count = FailureCount + 1, failures_since_last_success_count = FailuresSinceLastSuccessCount + 1};
count_failure (undefined) ->
  #dns_stats{failure_count = 1, failures_since_last_success_count = 1}.


create_table() ->
  ets:new(?MODULE, [ set, public, named_table, {keypos, #dns_rec.hostname}
                   , {read_concurrency, true}, {write_concurrency, true} ]).

destroy_table() ->
  ets:delete(?MODULE).

reset_table() ->
  ets:delete_all_objects(?MODULE).

check_table () ->
  case ets:info(?MODULE, size) of
    undefined -> {table_missing, 0};
    N         -> {ok, N}
  end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

min_ttl_test () ->
  Addr = {0, 1, 2, 3},
  ?assertEqual(100, min_ttl_ts_helper([], 100)),
  ?assertEqual(100, min_ttl_ts_helper([ {Addr, 101}, {Addr, 102} ], 100)),
  ?assertEqual(99, min_ttl_ts_helper([ {Addr, 99}, {Addr, 101} ], 100)),
  ?assertEqual(99, min_ttl_ts_helper([ {Addr, 101}, {Addr, 99} ], 100)),
  ?assertEqual(99, min_ttl_ts_helper([ {Addr, infinity}, {Addr, 99} ], 100)),
  ?assertEqual(100, min_ttl_ts_helper([ {Addr, 101}, {Addr, infinity} ], 100)),
  ok.

%% Make a dummy ip_entry.
-define(A(N, TTL), {{N, N, N, N}, TTL}).

merge_addrs_test () ->
  TS0 = 0,

  ?assertMatch(
     {{?A(1, 300)}, ?DNS_DYNAMIC},
     merge_addrs({[ ?A(1, 300) ], 1}, undefined, TS0)),
  %% Keep the max TTL.
  ?assertMatch(
     {{?A(1, 300)}, _},
     merge_addrs({[ ?A(1, 300) ], 1}, {?A(1, 200)}, TS0)),
  ?assertMatch(
     {{?A(1, 400)}, _},
     merge_addrs({[ ?A(1, 300) ], 1}, {?A(1, 400)}, TS0)),
  ?assertMatch(
     {{?A(1, 400)}, _},
     merge_addrs({[ ?A(1, 300) ], 1}, {?A(1, 400)}, TS0)),

  TS200 = 200,

  %% Short vs long TTL, don't keep cache.
  ?assertMatch(
     {{?A(2, 300)}, ?DNS_DYNAMIC},
     merge_addrs({[ ?A(2, 300) ], 1}, {?A(1, 100)}, TS200)),
  %% Short vs long TTL, keep cache.
  ?assertMatch(
     {{?A(1, 250), ?A(2, 300)}, ?DNS_DYNAMIC},
     merge_addrs({[ ?A(2, 300) ], 1}, {?A(1, 250)}, TS200)),
  ok.

-endif. %% TEST
