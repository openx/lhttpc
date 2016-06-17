-module(lhttpc_dns).

-export([ init/0
        , create_table/0
        , create_table_if_not_exists/0
        , destroy_table/0
        , reset_table/0
        , lookup/1
        , lookup_uncached/1
        , os_timestamp/0
        ]).


init () ->
  create_table().

choose_addr(IPAddrs) when is_tuple(IPAddrs) ->
  %% We should round-robin through the IP addresses, but for now we
  %% just choose a random one.
  case size(IPAddrs) of
    0    -> undefined;
    1    -> element(1, IPAddrs);
    Size -> element(random:uniform(Size), IPAddrs)
  end;
choose_addr(undefined) -> undefined.


os_timestamp() ->
  %% We wrap os:timestamp so that the unit tests can mock it.
  os:timestamp().


-define(ERROR_CACHE_SECONDS, 1).
-define(SUCCESS_CACHE_EXTRA_SECONDS, 2).
-define(MAX_CACHE_SECONDS, (3600 * 24)).
-define(MIN_CACHE_SECONDS_DEFAULT, 300).
-define(MAX_CACHE_SIZE, 10000).

-type lhttpc_dns_counts() :: { SuccessCount :: non_neg_integer()
                             , FailureCount :: non_neg_integer()
                             , FailuresSinceLastSuccessCount :: non_neg_integer()
                             , SuccessTime :: erlang:timestamp() | 'undefined' }.

-spec lookup(Host::string()) -> tuple() | 'undefined' | string().
lookup (Host) ->
  %% Attempt cache lookup.  Each row in the lhttpc_dns ets table has a tuple
  %% of the form:
  %%
  %% { Hostname
  %% , IPAddrTuple: tuple of one or more IP address tuples, or 'undefined'.
  %% , CacheExpireTime: timestamp() when cache line expires.
  %% , {SuccessCount, FailureCount, FailuresSinceLastSuccessCount, LastSuccessTime}
  %% }
  {WantRefresh, CachedIPAddrs, Now, CachedCounts} =
    try ets:lookup(?MODULE, Host) of
      [] ->                                             % Not in cache.
        {true, undefined, lhttpc_dns:os_timestamp(), undefined};
      [{_, IPAddrs0, Expiration, CachedCounts0}] ->     % Cached, maybe stale.
        Now0 = lhttpc_dns:os_timestamp(),
        {Now0 >= Expiration, IPAddrs0, Now0, CachedCounts0}
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
      {{IPAddrs, TTL}, Counts} =
        case lhttpc_dns:lookup_uncached(Host) of
          FailureLookup = {undefined, _} ->
            %% If the lookup fails but we have a stale cached result, keep it.
            UpdatedFailureLookup =
              case CachedIPAddrs of
                undefined -> FailureLookup;
                _         -> {CachedIPAddrs, min_cache_seconds()}
              end,
            {UpdatedFailureLookup, count_failure(CachedCounts)};
          SuccessLookup ->
            {SuccessLookup, count_success(CachedCounts, Now)}
        end,
      ets_insert_bounded(?MODULE, {Host, IPAddrs, timestamp_add_seconds(Now, TTL), Counts}),
      choose_addr(IPAddrs)
  end.


-spec lookup_uncached(Host::string()) -> {IPAddrs::tuple()|'undefined', CacheSeconds::non_neg_integer()}.
lookup_uncached (Host) ->
  %% inet_parse:address is not a public interface.  In R16B you can
  %% call inet:parse_address instead.
  case inet_parse:address(Host) of
    {ok, IPAddr} ->
      %% If Host looks like an IP address already, just return it.
      {{IPAddr}, ?MAX_CACHE_SECONDS};
    _ ->
      %% Otherwise do a DNS lookup for the hostname.
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
                      {[ IPAddr | IPAddrAcc ], min(MinTTL, TTL + ?SUCCESS_CACHE_EXTRA_SECONDS)};
                    _ ->
                      %% Ignore type=cname records in the answers.
                      {IPAddrAcc, MinTTL}
                  end
              end, {[], ?MAX_CACHE_SECONDS}, Answers),
          case IPAddrs of
            [] -> %% Answer was empty or contained no A records.  Treat it like a failure.
                  {undefined, ?ERROR_CACHE_SECONDS};
            _  -> {list_to_tuple(IPAddrs), max(TTL, min_cache_seconds())}
          end;
        _Error ->
          %% Cache an error lookup for one second.
          {undefined, ?ERROR_CACHE_SECONDS}
      end
  end.


-spec ets_insert_bounded(Tab::ets:tab(), Entry::term()) -> 'true'.
%% Insert the row `Entry' into the ETS table `Tab'.  Prevent the
%% unbounded growth of the ETS table by clearing it if it grows to
%% more than ?MAX_CACHE_SIZE entries.
ets_insert_bounded(Tab, Entry) ->
  case ets:info(Tab, size) of
    N when N >= ?MAX_CACHE_SIZE -> ets:delete_all_objects(Tab);
    _                           -> ok
  end,
  ets:insert(Tab, Entry).


-define(TEN_E6, 1000000).
timestamp_add_seconds ({MegaSeconds, Seconds, MicroSeconds}, AddSeconds) ->
  S1 = Seconds + AddSeconds,
  if S1 >= ?TEN_E6 ->
      {MegaSeconds + (S1 div ?TEN_E6), S1 rem ?TEN_E6, MicroSeconds};
     true ->
      {MegaSeconds, S1, MicroSeconds}
  end.


-spec min_cache_seconds() -> MinCacheSeconds::non_neg_integer().
min_cache_seconds() ->
  case application:get_env(lhttpc, dns_cache_min_cache_seconds) of
    {ok, MinCacheSeconds} -> MinCacheSeconds;
    _                     -> ?MIN_CACHE_SECONDS_DEFAULT
  end.


-spec count_success(Counts::lhttpc_dns_counts()|'undefined', Now::erlang:timestamp()) -> lhttpc_dns_counts().
count_success({SuccessCount, FailureCount, _FailuresSinceLastSuccessCount, _LastSuccessTime}, Now) ->
  {SuccessCount + 1, FailureCount, 0, Now};
count_success(undefined, Now) ->
  {1, 0, 0, Now}.


-spec count_failure(Counts::lhttpc_dns_counts()|'undefined') -> lhttpc_dns_counts().
count_failure({SuccessCount, FailureCount, FailuresSinceLastSuccessCount, LastSuccessTime}) ->
  {SuccessCount, FailureCount + 1, FailuresSinceLastSuccessCount + 1, LastSuccessTime};
count_failure(undefined) ->
  {0, 1, 1, undefined}.


create_table() ->
  ets:new(?MODULE, [ set, public, named_table, {read_concurrency, true}, {write_concurrency, true} ]).

destroy_table() ->
  ets:delete(?MODULE).

reset_table() ->
  ets:delete_all_objects(?MODULE).

create_table_if_not_exists () ->
  case ets:info(?MODULE, size) of
    undefined -> catch create_table(),
                 {table_created, 0};
    N         -> {ok, N}
  end.
