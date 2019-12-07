-module(lhttpc_stats).

-behaviour(gen_server).

-export([start_link/1, enable_stats/1, stats_enabled/0, record/2, print/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(lhttpc_stats_state, {stats_enabled=false :: boolean()}).

-define(STATS_KEYPOS, 2).
-define(DEBUG(Expr), ok).

-type hps_key() :: {Host::lhttpc_lb:host(), Port::lhttpc_lb:port_number(), Ssl::boolean()}.
-type conn_key() :: lhttpc_lb:socket().

-record(start_time, {key = start_time :: 'start_time',
                     start_time = erlang:monotonic_time() :: integer()}).

%% Per-host/port/ssl stats.
-record(hps_stats, {key :: hps_key(),
                    request_count=0 :: integer(),
                    connection_count=0 :: integer(),
                    connection_error_count=0 :: integer(),
                    connection_remote_close_count=0 :: integer(),
                    connection_local_close_count=0 :: integer(),
                    connection_cumulative_lifetime_usec=0 :: integer()}).

%% Per-connection stats.
-record(conn_stats, {key :: conn_key(),
                     hps_key :: hps_key(),
                     request_count=0 :: integer(),
                     open_time :: integer() | undefined,
                     last_idle_time :: integer() | undefined,
                     longest_idle_time_usec=0 :: integer()
                   , pid :: pid() | undefined
                    }).


%%%
%%% EXTERNAL INTERFACE
%%%

-spec start_link(KeepStats::boolean()) -> {ok, pid()}.
start_link(KeepStats) when is_boolean(KeepStats) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, KeepStats, []).


-spec enable_stats(KeepStats::boolean()) -> ok.
enable_stats(KeepStats) when is_boolean(KeepStats) ->
    gen_server:cast(?MODULE, {enable_stats, KeepStats}).


-spec stats_enabled() -> boolean().
stats_enabled() ->
    ets:info(?MODULE, size) =/= undefined.


-spec record(open_connection, {HPSKey::hps_key(), Socket::lhttpc_lb:socket()}) -> ok;
            (open_connection_error, HPSKey::hps_key()) -> ok;
            (close_connection_remote, Socket::lhttpc_lb:socket()) -> ok;
            (close_connection_local, Socket::lhttpc_lb:socket()) -> ok;
            (close_connection_timeout, Pid::pid()) -> ok;
            (start_request, {HPSKey::hps_key(), Socket::lhttpc_lb:socket(), Pid::pid()}) -> ok;
            (end_request, Socket::lhttpc_lb:socket()) -> ok.

record(Stat, Arg) ->
    try
        record_untrapped(Stat, Arg)
    catch
        error:badarg -> ok
    end.

record_untrapped(open_connection, {HPSKey, Socket}) ->
    case stats_enabled() of
        true ->
            try ets:update_counter(?MODULE, HPSKey, {#hps_stats.connection_count, 1})
            catch
                error:badarg ->
                    ets:insert_new(?MODULE, #hps_stats{key=HPSKey, connection_count=1})
            end,
            ets:insert_new(?MODULE, #conn_stats{key=Socket, hps_key=HPSKey, open_time=erlang:monotonic_time()}),
            ok;
        false -> ok
    end;

record_untrapped(open_connection_error, HPSKey) ->
    case stats_enabled() of
        true ->
            try ets:update_counter(?MODULE, HPSKey, [ {#hps_stats.connection_count, 1},
                                                      {#hps_stats.connection_error_count, 1} ])
            catch
                error:badarg ->
                    ets:insert_new(?MODULE, #hps_stats{key=HPSKey, connection_count=1, connection_error_count=1})
            end,
            ok;
        false -> ok
    end;

record_untrapped(close_connection_remote, Socket) ->
    case stats_enabled() of
        true ->
            case ets:lookup(?MODULE, Socket) of
                [#conn_stats{open_time=undefined}] ->
                    throw(bad_open_time); % shouldn't happen
                [#conn_stats{hps_key=HPSKey, open_time=OpenTime}] ->
                    Lifetime = erlang:convert_time_unit(erlang:monotonic_time() - OpenTime, native, micro_seconds),
                    ets:update_counter(?MODULE, HPSKey, [ {#hps_stats.connection_remote_close_count, 1},
                                                          {#hps_stats.connection_cumulative_lifetime_usec, Lifetime} ]),
                    ets:delete(?MODULE, Socket),
                    ok;
                [] ->
                    ?DEBUG(io:format(standard_error, "A: not found: ~p\n", [ Socket ])),
                    ?DEBUG(throw(not_found))
            end;
        false -> ok
    end;

record_untrapped(close_connection_local, Socket) ->
    case stats_enabled() of
        true ->
            case ets:lookup(?MODULE, Socket) of
                [#conn_stats{open_time=undefined}] ->
                    throw(bad_open_time); % shouldn't happen
                [#conn_stats{hps_key=HPSKey, open_time=OpenTime}] ->
                    Lifetime = erlang:convert_time_unit(erlang:monotonic_time() - OpenTime, native, micro_seconds),
                    ets:update_counter(?MODULE, HPSKey, [ {#hps_stats.connection_local_close_count, 1},
                                                          {#hps_stats.connection_cumulative_lifetime_usec, Lifetime} ]),
                    ets:delete(?MODULE, Socket),
                    ok;
                [] ->
                    ?DEBUG(io:format(standard_error, "B: not found: ~p\n", [ Socket ])),
                    ?DEBUG(throw(not_found))
            end;
        false -> ok
    end;

record_untrapped(close_connection_timeout, Socket) ->
    case stats_enabled() of
        true ->
            case ets:lookup(?MODULE, Socket) of
                [#conn_stats{open_time=undefined}] ->
                    throw(bad_open_time); % shouldn't happen
                [#conn_stats{hps_key=HPSKey, open_time=OpenTime}] ->
                    Lifetime = erlang:convert_time_unit(erlang:monotonic_time() - OpenTime, native, micro_seconds),
                    ets:update_counter(?MODULE, HPSKey, [ {#hps_stats.connection_local_close_count, 1},
                                                          {#hps_stats.connection_cumulative_lifetime_usec, Lifetime} ]),
                    ets:delete(?MODULE, Socket),
                    ok;
                [] ->
                    ?DEBUG(io:format(standard_error, "C: not found: ~p\n", [ Socket ])),
                    ?DEBUG(throw(not_found))
            end;
        false -> ok
    end;

record_untrapped(start_request, {HPSKey, Socket, Pid}) ->
    case stats_enabled() of
        true ->
            ets:update_counter(?MODULE, HPSKey, {#hps_stats.request_count, 1}),
            case ets:lookup(?MODULE, Socket) of
                [#conn_stats{last_idle_time=LastIdleTime, longest_idle_time_usec=LongestIdleTime}] ->
                    UpdateStats0 = [ {#conn_stats.request_count, 1} ],
                    UpdateStats1 = case LastIdleTime of
                                       TS when is_integer(TS) ->
                                           CurrentIdleTime = erlang:convert_time_unit(erlang:monotonic_time() - TS, native, micro_seconds),
                                           NewLongestIdleTime = max(LongestIdleTime, CurrentIdleTime),
                                           %% There is a race here, but what can you do?
                                           [ {#conn_stats.longest_idle_time_usec, 1, 0, NewLongestIdleTime} | UpdateStats0 ];
                                       undefined ->
                                           UpdateStats0
                                   end,
                    ets:update_counter(?MODULE, Socket, UpdateStats1),
                    ets:update_element(?MODULE, Socket, {#conn_stats.pid, Pid});
                [] ->
                    %% First request for socket.
                    %% This shouldn't happen. @@
                    %% ets:insert_new(?MODULE, #conn_stats{key=Socket, open_time=erlang:monotonic_time(), request_count=1, pid=Pid})
                    throw(missing_open_connection)
                end;
        false -> ok
    end;

record_untrapped(end_request, Socket) ->
    case stats_enabled() of
        true ->
            ets:update_element(?MODULE, Socket, {#conn_stats.last_idle_time, erlang:monotonic_time()}),
            ok;
        false -> ok
    end.


print() ->
    case stats_enabled() of
        true ->
            [ #start_time{start_time=StartTime} ] = ets:lookup(?MODULE, start_time),
            ServiceLifetime = erlang:convert_time_unit(erlang:monotonic_time() - StartTime, native, micro_seconds),

            io:format("Time: ~13.1f"     "                           Total     Total   Connect    Remote     Local          Avg # Avg Conn\n"
                      "Host                                       Requests   Sockets    Errors     Close     Close Act Idl  Conns     Time\n"
                      "---------------------------------------- ---------- --------- --------- --------- --------- --- --- ------ --------\n",
                     [ ServiceLifetime / 1000000 ]),
            lists:foreach(
              fun (#hps_stats{key={Host, Port, Ssl},
                              request_count=Requests, connection_count=Connections,
                              connection_error_count=ConnectError,
                              connection_remote_close_count=RemoteClose,
                              connection_local_close_count=LocalClose,
                              connection_cumulative_lifetime_usec=ConnectionLifetime}) ->
                      %% The connection_count call only gets stats for the first load balancer:
                      {ActiveConnections, IdleConnections} = lhttpc_lb:connection_count({Host, Port, Ssl, 1}),
                      io:format("~-40.40s ~10B ~9B ~9B ~9B ~9B ~3B ~3B ~6.2f ~8.2f\n",
                                [ io_lib:format("~s:~B", [ Host, Port ])
                                , Requests, Connections, ConnectError, RemoteClose, LocalClose
                                , ActiveConnections, IdleConnections
                                , ConnectionLifetime / ServiceLifetime
                                , divide(ConnectionLifetime, RemoteClose + LocalClose) / 1000000
                                ]);
                  (_) -> ok
              end, lists:sort(ets:tab2list(?MODULE)));
        false ->
            io:format("lhttpc_stats disabled\n"),
            ok
    end.


%%%
%%% GEN_SERVER CALLBACKS
%%%

init(KeepStats) ->
    enable_stats_internal(KeepStats),
    {ok, #lhttpc_stats_state{stats_enabled=KeepStats}}.

handle_call(stats_enabled, _From, State) ->
    {reply, State#lhttpc_stats_state.stats_enabled};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({enable_stats, EnableStats}, State) when is_boolean(EnableStats) ->
    enable_stats_internal(EnableStats),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%
%%% PRIVATE FUNCTIONS
%%%

enable_stats_internal (true) ->
    try
        ets:new(?MODULE, [ named_table, set, public, {keypos, ?STATS_KEYPOS}, {write_concurrency, true} ]),
        ets:insert_new(?MODULE, #start_time{start_time = erlang:monotonic_time()})
    catch
        error:badarg -> ok                      % Table already exists.
    end;
enable_stats_internal (false) ->
    try
        ets:delete(?MODULE)
    catch
        error:badarg -> ok                      % Table does not exist.
    end.


divide(_A, 0) -> 0.0;
divide(A, B)  -> A / B.
