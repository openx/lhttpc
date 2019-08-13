-module(lhttpc_dns).

-export([ init/1
        , create_table/0
        , check_table/0
        , destroy_table/0
        , reset_table/0
        , lookup/1
        , lookup_uncached/1
        , monotonic_time/0
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
-define(MAX_CACHE_SECONDS, (3600 * 24)).
-define(MIN_CACHE_SECONDS, 60).
-define(DYNAMIC_REQUERY_SECONDS, 5).
-define(MAX_CACHE_SIZE, 10000).


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
      {{IPAddrs, TTL}, Stats} =
        case lhttpc_dns:lookup_uncached(Host) of
          FailureLookup = {undefined, _} ->
            %% If the lookup fails but we have a stale cached result, keep it.
            UpdatedFailureLookup =
              case CachedIPAddrs of
                undefined -> FailureLookup;
                _         -> {CachedIPAddrs, ?MIN_CACHE_SECONDS}
              end,
            {UpdatedFailureLookup, count_failure(CachedStats)};
          SuccessLookup ->
            MergedLookup = merge_addrs(SuccessLookup, CachedIPAddrs, Now),
            {MergedLookup, count_success(CachedStats, Now)}
        end,
      ets_insert_bounded(?MODULE, #dns_rec{hostname = Host, ip_addrs = IPAddrs,
                                           expiration_time = Now + erlang:convert_time_unit(TTL, seconds, native),
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
                      TTLTS = Now + erlang:convert_time_unit(TTLAdjusted, second, native),
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


-spec merge_addrs({list(ip_entry()), ttl()}, ip_addrs() | 'undefined', native_time()) -> {CachedOut::ip_addrs(), RefreshSecs::ttl()}.
%% Merges a set of new DNS entries in `AddrsIn' into the cached DNS entries in
%% `CachedIn' and drops expired entries to produce `CachedOut'.
merge_addrs ({AddrsIn, TTLIn}, CachedIn, Now) ->
  AddrsMap = maps:from_list(AddrsIn),
  {AddrsOut, TTLType} =
    case CachedIn of
      undefined ->
        %% There are no cached addresses because this is the first call.  Use
        %% a short TTL.
        {AddrsIn, short_ttl};
      _ ->
        %% Copy unexpired entries from the old cache into the new cache.  If
        %% we have any carryovers, that's an indication that the DNS lookup is
        %% giving us a subset of a larger set of IP addresses; in that case,
        %% use a short TTL.
        lists:foldl(
          fun (CachedEntry={CachedAddr, CachedTS}, Acc={AddrsAcc, _TTLTypeAcc}) ->
              %% Drop the cached entry if it is too old or is contained in the
              %% new address list.  CachedTS may be 'infinity', which compares
              %% greater than any integer.
              case maps:is_key(CachedAddr, AddrsMap) of
                true      -> Acc;
                false ->
                  case CachedTS > Now of
                    true  -> {[ CachedEntry | AddrsAcc ], short_ttl};
                    false -> {AddrsAcc, short_ttl}
                  end
              end
          end, {AddrsIn, normal_ttl}, tuple_to_list(CachedIn))
    end,
  CachedOut = list_to_tuple(AddrsOut),

  %% Heuristic to decide whether to us a short or long min TTL.  We use a
  %% short TTL if we think that DNS is giving us one out of a larger set of IP
  %% addresses for each lookup.  We use a long TTL if we think that the DNS
  %% server is giving us all of the IP addresses.
  TTLOut =
    case TTLType of
      short_ttl  -> ?DYNAMIC_REQUERY_SECONDS;
      normal_ttl -> TTLIn
    end,

  {CachedOut, TTLOut}.


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
