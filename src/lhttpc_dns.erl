-module(lhttpc_dns).

-export([ init/1
        , create_table/0
        , check_table/0
        , destroy_table/0
        , reset_table/0
        , lookup/1
        , lookup_uncached/1
        , monotonic_time/0
        , print_cache/0
        , print_cache/1
        , print_tcpdump_hosts/1
        ]).


%% -include_lib("kernel/include/inet.hrl").


-type native_time() :: integer().
-type ttl() :: pos_integer().

-type ip_entry () :: {inet:ip_address(), native_time() | 'infinity'}.
%% Tuple of any length is OK, but 2 is enough to satisfy dialyzer.
-type ip_addrs () :: {ip_entry()} | {ip_entry(), ip_entry()}.

-type dns_stats() :: { SuccessCount :: non_neg_integer()
                     , FailureCount :: non_neg_integer()
                     , FailuresSinceLastSuccessCount :: non_neg_integer()
                     , SuccessTime :: integer() | 'undefined' }.

-record(dns_rec,
        { hostname :: inet:hostname()
        , ip_addrs :: ip_addrs()            % list_to_tuple(list(ip_entry())).
        , expiration_time :: native_time()
        , stats :: dns_stats()
        }).


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
      {{IPAddrs, RefreshTS}, Stats} =
        case lhttpc_dns:lookup_uncached(Host) of
          {undefined, FailureTTL} ->
            %% If the lookup fails but we have a stale cached result, keep it.
            UpdatedFailureLookup =
              case CachedIPAddrs of
                undefined -> {undefined, ?TTL_TO_TS(FailureTTL, Now)};
                _         -> {CachedIPAddrs, ?TTL_TO_TS(?MIN_CACHE_SECONDS, Now)}
              end,
            {UpdatedFailureLookup, count_failure(CachedStats)};
          SuccessLookup ->
            MergedLookup = merge_addrs(SuccessLookup, CachedIPAddrs, Now),
            {MergedLookup, count_success(CachedStats, Now)}
        end,
      ets_insert_bounded(?MODULE, #dns_rec{hostname = Host, ip_addrs = IPAddrs,
                                           expiration_time = RefreshTS,
                                           stats = Stats}),
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


-spec merge_addrs({list(ip_entry()), ttl()}, ip_addrs() | 'undefined', native_time()) -> {CachedOut::ip_addrs(), RefreshTS::native_time()}.
%% Merges a set of new DNS entries in `AddrsIn' into the cached DNS entries in
%% `CachedIn' and drops expired entries to produce `CachedOut'.
merge_addrs ({AddrsIn, _TTLIn}, CachedIn, Now) ->
  AddrsInMap = maps:from_list(AddrsIn),
  {AddrsOutMap, TTLType} =
    case CachedIn of
      undefined ->
        %% There are no cached addresses because this is the first call.  Use
        %% a short TTL.
        {AddrsInMap, short_ttl};
      _ ->
        %% Copy unexpired entries from the old cache into the new cache.  If
        %% we have any carryovers, that's an indication that the DNS lookup is
        %% giving us a subset of a larger set of IP addresses; in that case,
        %% use a short TTL.
        lists:foldl(
          fun ({CachedAddr, CachedTS}, Acc={AddrsAcc, TTLTypeAcc}) ->
              case maps:get(CachedAddr, AddrsAcc, undefined) of
                undefined ->
                  %% The cached entry was not found in the new address list.
                  %% Keep it if it isn't too old.  Use a short TTL.  CachedTS
                  %% may be 'infinity', which compares greater than any
                  %% integer.
                  case CachedTS > Now of
                    true        -> {maps:put(CachedAddr, CachedTS, AddrsAcc), short_ttl};
                    false       -> {AddrsAcc, short_ttl}
                  end;
                NewTS ->
                  %% The cached entry was found in the new address list.  If
                  %% use the greater of the cached TTL and the new TTL for the
                  %% entry's TTL.
                  case CachedTS > NewTS of
                    true        -> {maps:put(CachedAddr, CachedTS, AddrsAcc), TTLTypeAcc};
                    false       -> Acc
                  end
              end
          end, {AddrsInMap, normal_ttl}, tuple_to_list(CachedIn))
    end,
  AddrsOut = maps:to_list(AddrsOutMap),

  %% Heuristic to decide whether to us a short or long min TTL.  We use a
  %% short TTL if we think that DNS is giving us one out of a larger set of IP
  %% addresses for each lookup.  We use a long TTL if we think that the DNS
  %% server is giving us all of the IP addresses.  We use less than the DNS
  %% TTL in the long TTL case because we want to collect IPs from multiple DNS
  %% lookups.
  TSOut =
    case TTLType of
      short_ttl  -> ?TTL_TO_TS(?DYNAMIC_REQUERY_SECONDS, Now);
      normal_ttl -> max(min_ttl_ts(AddrsOut, ?TTL_TO_TS(?MAX_CACHE_SECONDS, Now)),
                        ?TTL_TO_TS(?DYNAMIC_REQUERY_SECONDS, Now))
    end,

  {list_to_tuple(AddrsOut), TSOut}.


-spec min_ttl_ts(list(ip_entry()), integer()) -> integer().
min_ttl_ts ([ {_, infinity} | Rest ], MinTTL) -> min_ttl_ts(Rest, MinTTL);
min_ttl_ts ([ {_, TTL} | Rest ], MinTTL) -> min_ttl_ts(Rest, min(TTL, MinTTL));
min_ttl_ts ([], MinTTL) -> MinTTL.


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

print_cache_entry (#dns_rec{hostname=Hostname, ip_addrs=IPAddrs, expiration_time=ExpirationTime, stats={S, F, FS, STS}}, Now) ->
  IPAddrsIOList = [ io_lib:format("  ~s ~p\n", [ inet:ntoa(IPAddr), ?TS_TO_TTL(TS, Now) ]) || {IPAddr, TS} <- tuple_to_list(IPAddrs) ],
  io:format("~s ttl: ~p sec (~p)\n~s  successes: ~p; failures: ~p; failures_since_last_success: ~p; success_time: ~p sec_ago\n",
            [ Hostname, ?TS_TO_TTL(ExpirationTime, Now), ExpirationTime - Now
            , IPAddrsIOList
            , S, F, FS, ?TS_TO_TTL(Now, STS)
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
count_success({SuccessCount, FailureCount, _FailuresSinceLastSuccessCount, _LastSuccessTime}, Now) ->
  {SuccessCount + 1, FailureCount, 0, Now};
count_success(undefined, Now) ->
  {1, 0, 0, Now}.


-spec count_failure(Stats::dns_stats()|'undefined') -> dns_stats().
count_failure({SuccessCount, FailureCount, FailuresSinceLastSuccessCount, LastSuccessTime}) ->
  {SuccessCount, FailureCount + 1, FailuresSinceLastSuccessCount + 1, LastSuccessTime};
count_failure(undefined) ->
  {0, 1, 1, undefined}.


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
  ?assertEqual(100, min_ttl_ts([], 100)),
  ?assertEqual(100, min_ttl_ts([ {Addr, 101}, {Addr, 102} ], 100)),
  ?assertEqual(99, min_ttl_ts([ {Addr, 99}, {Addr, 101} ], 100)),
  ?assertEqual(99, min_ttl_ts([ {Addr, 101}, {Addr, 99} ], 100)),
  ?assertEqual(99, min_ttl_ts([ {Addr, infinity}, {Addr, 99} ], 100)),
  ?assertEqual(100, min_ttl_ts([ {Addr, 101}, {Addr, infinity} ], 100)),
  ok.

%% Make a dummy ip_entry.
-define(A(N, TTL), {{N, N, N, N}, TTL}).

merge_addrs_test () ->
  TS0 = 0,
  DynamicTS0 = ?TTL_TO_TS(?DYNAMIC_REQUERY_SECONDS, TS0),

  ?assertMatch(
     {{?A(1, 300)}, DynamicTS0},
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
  DynamicTS200 = ?TTL_TO_TS(?DYNAMIC_REQUERY_SECONDS, TS200),

  %% Short vs long TTL, don't keep cache.
  ?assertMatch(
     {{?A(2, 300)}, DynamicTS200},
     merge_addrs({[ ?A(2, 300) ], 1}, {?A(1, 100)}, TS200)),
  %% Short vs long TTL, keep cache.
  ?assertMatch(
     {{?A(1, 250), ?A(2, 300)}, DynamicTS200},
     merge_addrs({[ ?A(2, 300) ], 1}, {?A(1, 250)}, TS200)),
  ok.

-endif. %% TEST
