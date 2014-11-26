-module(lhttpc_dns).

-export([ init/0
        , create_table/0
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
-define(MIN_CACHE_SECONDS, 300).


-spec lookup(Host::string()) -> tuple() | 'undefined' | string().
lookup (Host) ->
  %% Attempt cache lookup.
  {WantRefresh, CachedIPAddrs, Now} =
    try ets:lookup(?MODULE, Host) of
      [] ->                                     % Not in cache.
        {true, undefined, lhttpc_dns:os_timestamp()};
      [{_, IPAddrs0, Expiration}] ->            % Cached but maybe stale.
        Now0 = lhttpc_dns:os_timestamp(),
        {Now0 >= Expiration, IPAddrs0, Now0}
    catch
      error:badarg ->
        {fallback, undefined, undefined}
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
      {IPAddrs, TTL} =
        case lhttpc_dns:lookup_uncached(Host) of
          FailureLookup = {undefined, _} ->
            %% If the lookup fails but we have a stale cached result, keep it.
            case CachedIPAddrs of
              undefined -> FailureLookup;
              _         -> {CachedIPAddrs, ?MIN_CACHE_SECONDS}
            end;
          SuccessLookup -> SuccessLookup
        end,
      ets:insert(?MODULE, {Host, IPAddrs, timestamp_add_seconds(Now, TTL)}),
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
          case inet_dns:msg(DNSRec, anlist) of
            [] -> {undefined, ?ERROR_CACHE_SECONDS};
            Answers ->
              {IPAddrs, TTL} =
                lists:foldl(fun (Answer, {IPAddrAcc, MinTTL}) ->
                                [ IPAddr, TTL ] = inet_dns:rr(Answer, [ data, ttl ]),
                                %% Cache a successful lookup for an additional
                                %% 2 seconds.
                                {[ IPAddr | IPAddrAcc ], min(MinTTL, TTL + ?SUCCESS_CACHE_EXTRA_SECONDS)}
                            end, {[], ?MAX_CACHE_SECONDS}, Answers),
              {list_to_tuple(IPAddrs), max(TTL, ?MIN_CACHE_SECONDS)}
          end;
        _Error ->
          %% Cache an error lookup for one second.
          {undefined, ?ERROR_CACHE_SECONDS}
      end
  end.


-define(TEN_E6, 1000000).
timestamp_add_seconds ({MegaSeconds, Seconds, MicroSeconds}, AddSeconds) ->
  S1 = Seconds + AddSeconds,
  if S1 >= ?TEN_E6 ->
      {MegaSeconds + (S1 div ?TEN_E6), S1 rem ?TEN_E6, MicroSeconds};
     true ->
      {MegaSeconds, S1, MicroSeconds}
  end.


create_table() ->
  ets:new(?MODULE, [ set, public, named_table, {read_concurrency, true}, {write_concurrency, true} ]).

destroy_table() ->
  ets:delete(?MODULE).

reset_table() ->
  ets:delete_all_objects(?MODULE).
