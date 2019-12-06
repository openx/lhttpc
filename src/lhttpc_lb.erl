%%% Load balancer for lhttpc, replacing the older lhttpc_manager.
%%% Takes a similar stance of storing used-but-not-closed sockets.
%%% Also adds functionality to limit the number of simultaneous
%%% connection attempts from clients.
-module(lhttpc_lb).
-behaviour(gen_server).
-export([start_link/1, checkout/7, checkin/5, connection_count/3, connection_count/4, connection_count/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-define(SHUTDOWN_DELAY, 10000).
-define(LB_MAX_CONNECTIONS, 150).

%% TODO: transfert_socket, in case of checkout+give_away

-record(config,
        {host :: host(),
         port :: port_number(),
         ssl :: boolean(),
         lb_index :: non_neg_integer(),
         max_conn :: max_connections(),
         timeout :: timeout(),
         request_limit :: request_limit(),
         conn_lifetime :: connection_lifetime()}).

-record(conn_info,
        {socket :: socket() | 'no_socket',
         request_count = 0 :: non_neg_integer(),
         expire :: integer() | undefined}).

-record(conn_free,
        {socket :: socket(),
         timer_ref :: reference() | 'undefined',
         conn_info :: conn_info()}).

-record(state,
        {config :: config(),
         clients :: ets:tid(),
         free=[] :: list(conn_free())}).


-export_types([host/0, port_number/0, socket/0, max_connections/0, request_limit/0, connection_lifetime/0, connection_timeout/0]).
-type config() :: #config{}.
-type host() :: inet:ip_address()|string().
-type port_number() :: 1..65535.
-type socket() :: gen_tcp:socket() | ssl:sslsocket().
-type max_connections() :: pos_integer().
-type request_limit() :: pos_integer() | 'infinity'.
-type connection_lifetime() :: pos_integer() | 'infinity'.
-type connection_timeout() :: timeout().
-type conn_info() :: #conn_info{}.
-type conn_free() :: #conn_free{}.


-spec start_link(config()) -> {ok, pid()}.
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec checkout(host(), port_number(), SSL::boolean(),
               max_connections(), connection_timeout(),
               request_limit(), connection_lifetime()) ->
        {ok, pid(), conn_info(), socket()} | retry_later | {no_socket, pid(), conn_info()}.
checkout(Host, Port, Ssl, MaxConn, ConnTimeout, RequestLimit, ConnLifetime) ->
    {LbIndex, LbMaxConn} =
        %% The per-load-balancer max_connections is just approximate when
        %% there are multiple load balancers.
        if MaxConn > ?LB_MAX_CONNECTIONS -> {rand:uniform((MaxConn + ?LB_MAX_CONNECTIONS - 1) div ?LB_MAX_CONNECTIONS), ?LB_MAX_CONNECTIONS};
           true                          -> {1, MaxConn}
        end,
    Config = #config{host = Host, port = Port, ssl = Ssl, lb_index = LbIndex,
                     max_conn = LbMaxConn, timeout = ConnTimeout,
                     request_limit = RequestLimit, conn_lifetime = ConnLifetime},
    Lb = find_or_start_lb(Config),
    gen_server:call(Lb, {checkout, self(), LbMaxConn, ConnLifetime}, infinity).

%% Called when we're done and the socket can still be reused
-spec checkin(pid(), conn_info(), SSL::boolean(), Socket::socket(), TransferOwnership::boolean()) -> ok.
checkin(Lb, ConnInfo, Ssl, Socket, TransferOwnership) ->
    %% If the socket's expire time has been reached close the socket here in
    %% the client instead of in the load balancer so in case it is slow it
    %% does not block other requests.  The load balancer will call close on
    %% the socket a second time.
    expire_time_reached(ConnInfo) andalso
        lhttpc_sock:close(Socket, Ssl),

    %% We need to return the socket to the load balancer before making it the
    %% controlling process to prevent a race; see commit message for more
    %% info.
    gen_server:cast(Lb, {checkin, self(), Socket}),
    if TransferOwnership -> lhttpc_sock:controlling_process(Socket, Lb, Ssl), ok;
       true              -> ok
    end.

%% Returns a tuple with the number of active (currently in use) and
%% the number of idle (open but not currently in use) connections for
%% the host, port, and SSL state.
%%
%% The three-argument form is a temporary hack for applications that don't
%% understand that there can be multiple load balancers for a particular host.
%% This is for the use of the component tests.
-spec connection_count(host(), port_number(), Ssl::boolean()) ->
                       {ActiveConnections::integer(), IdleConnections::integer()}.
connection_count(Host, Port, Ssl) ->
    connection_count({Host, Port, Ssl, 1}).

-spec connection_count(host(), port_number(), Ssl::boolean(), LbIndex::non_neg_integer()) ->
                       {ActiveConnections::integer(), IdleConnections::integer()}.
connection_count(Host, Port, Ssl, LbIndex) ->
    connection_count({Host, Port, Ssl, LbIndex}).

connection_count(Name) ->
    case find_lb(Name) of
        {error, undefined} -> {0, 0};
        {ok, Pid} -> gen_server:call(Pid, {connection_count})
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init(Config=#config{host=Host, port=Port, ssl=Ssl, lb_index=LbIndex}) ->
    %% Write host config to process dictionary so that it can be fetched with
    %% `process_info(Pid, dictionary)'.  This allows us to easily discover the
    %% host of a load balancer that is having problems.
    put(lhttpc_lb_host, {Host, Port, Ssl, LbIndex}),

    %% we must use insert_new because it is possible a concurrent request is
    %% starting such a server at exactly the same time.
    case ets:insert_new(?MODULE, {{Host, Port, Ssl, LbIndex}, self()}) of
        true ->
            {ok, #state{config=Config,
                        clients=ets:new(clients, [set, private])}};
        false ->
            ignore
    end.

handle_call({checkout, Pid, MaxConn, ConnLifetime}, _From, S0=#state{free=[], clients=Tid}) ->
    %% Update the state if this call updates the max_conn or conn_lifetime.
    S1 = case S0#state.config of
             #config{max_conn=MaxConn, conn_lifetime=ConnLifetime} -> S0;
             StaleConfig -> S0#state{config = StaleConfig#config{max_conn = MaxConn, conn_lifetime = ConnLifetime}}
         end,
    Size = ets:info(Tid, size),
    case Size < MaxConn of
        true ->
            %% We don't have an open socket, but the client can open one.
            Expire =
                case ConnLifetime of
                    infinity -> undefined;
                    _        -> CLNative = erlang:convert_time_unit(ConnLifetime, milli_seconds, native),
                                %% Add 20% jitter to connection lifetime.
                                CLNativeJitter = CLNative + rand:uniform(CLNative div 5),
                                erlang:monotonic_time() + CLNativeJitter
                end,
            ConnInfo = #conn_info{socket = no_socket, request_count = 1, expire = Expire},
            add_client(Tid, Pid, ConnInfo),
            {reply, {no_socket, self(), ConnInfo}, S1};
        false ->
            {reply, retry_later, S1}
    end;
handle_call({checkout, Pid, MaxConn, ConnLifetime}, _From,
            S0=#state{free=[#conn_free{socket=Taken, timer_ref=Timer, conn_info=ConnInfo} | Free], clients=Tid}) ->
    %% Update the state if this call updates the max_conn or conn_lifetime.
    S1 = case S0#state.config of
             #config{max_conn=MaxConn, conn_lifetime=ConnLifetime} -> S0;
             StaleConfig -> S0#state{config = StaleConfig#config{max_conn = MaxConn, conn_lifetime = ConnLifetime}}
         end,
    cancel_timer(Timer, Taken),
    ConnInfo0 = ConnInfo#conn_info{request_count = ConnInfo#conn_info.request_count + 1},
    add_client(Tid, Pid, ConnInfo0),
    {reply, {ok, self(), ConnInfo0, Taken}, S1#state{free=Free}};

handle_call({connection_count}, _From, S = #state{free=Free, clients=Tid}) ->
    {reply, {ets:info(Tid, size), length(Free)}, S};

handle_call(_Msg, _From, S) ->
    {noreply, S}.

handle_cast({checkin, Pid, Socket}, S = #state{config=Config=#config{ssl=Ssl, max_conn=MaxConn, timeout=T}, clients=Tid, free=Free}) ->
    lhttpc_stats:record(end_request, Socket),
    {SocketAction, ConnInfo1} =
        case remove_client(Tid, Pid, Ssl, checkin) of
            undefined          -> {close_connection_local, undefined};
            ConnInfo0 ->
                case request_limit_reached(ConnInfo0, Config) orelse
                    expire_time_reached(ConnInfo0) orelse
                    ets:info(Tid, size) >= MaxConn
                of
                    true       -> {close_connection_local, ConnInfo0};
                    false      -> {keep_socket, ConnInfo0#conn_info{socket = Socket}}
                end
        end,
    case SocketAction of
        keep_socket ->
            Timer = start_timer(Socket,T),
            {noreply, S#state{free=[#conn_free{socket = Socket, timer_ref = Timer, conn_info = ConnInfo1} | Free]}};
        CloseConnectionType ->
            noreply_maybe_shutdown(remove_socket(Socket, CloseConnectionType, S))
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, S=#state{clients=Tid, config=#config{ssl=Ssl}}) ->
    %% Client died
    case Reason of
        normal      -> ok;
        noproc      -> ok; %% A client made a request but died before we could start monitoring it.
        timeout     -> lhttpc_stats:record(close_connection_timeout, Pid);
        OtherReason -> io:format(standard_error, "DOWN ~p\n", [ OtherReason ])
    end,
    remove_client(Tid, Pid, Ssl, down),
    noreply_maybe_shutdown(S);
handle_info({timeout, Socket}, State) ->
    %% Fired by start_timer to close idle sockets.
    noreply_maybe_shutdown(remove_socket(Socket, close_connection_remote, State));
handle_info(timeout, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{config=#config{host=H, port=P, ssl=Ssl, lb_index=LbIndex}, free=Free, clients=Tid}) ->
    ets:delete(Tid),
    ets:delete(?MODULE,{H, P, Ssl, LbIndex}),
    lists:foreach(fun (#conn_free{socket=Socket}) ->
                          lhttpc_stats:record(close_connection_local, Socket),
                          lhttpc_sock:close(Socket,Ssl)
                  end, Free),
    ok.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

%% Potential race condition: if the lb shuts itself down after a while, it
%% might happen between a read and the use of the pid. A busy load balancer
%% should not have this problem.
-spec find_or_start_lb(config()) -> pid().
find_or_start_lb(Config=#config{host=Host, port=Port, ssl=Ssl, lb_index=LbIndex}) ->
    Name = {Host, Port, Ssl, LbIndex},
    case ets:lookup(?MODULE, Name) of
        [] ->
            case supervisor:start_child(lhttpc_lb_sup, [ Config ]) of
                {ok, undefined} -> find_or_start_lb(Config);
                {ok, Pid} -> Pid
            end;
        [{_Name, Pid}] ->
            case is_process_alive(Pid) of % lb died, stale entry
                true -> Pid;
                false ->
                    ets:delete(?MODULE, Name),
                    find_or_start_lb(Config)
            end
    end.

%% Version of the function to be used when we don't want to start a load balancer
%% if none is found
-spec find_lb(Name::{host(), port_number(), boolean(), non_neg_integer()}) -> {error, undefined} | {ok, pid()}.
find_lb(Name={_Host, _Port, _Ssl, _LbIndex}) ->
    case ets:lookup(?MODULE, Name) of
        [] -> {error, undefined};
        [{_Name, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> % lb died, stale entry
                    ets:delete(?MODULE,Name),
                    {error, undefined}
            end
    end.

-spec add_client(ets:tid(), pid(), conn_info()) -> ok.
add_client(Tid, Pid, ConnInfo) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(Tid, {Pid, Ref, ConnInfo}),
    ok.

-spec remove_client(ets:tid(), pid(), Ssl::boolean(), 'checkin'|'down') -> conn_info() | undefined.
remove_client(Tid, Pid, Ssl, Status) ->
    case ets:lookup(Tid, Pid) of
        [] -> undefined; % client already removed
        [{_Pid, Ref, ConnInfo}] ->
            erlang:demonitor(Ref, [flush]),
            ets:delete(Tid, Pid),
            Socket = ConnInfo#conn_info.socket,
            Status =:= down andalso Socket =/= no_socket andalso
                lhttpc_sock:close(Socket, Ssl),
            ConnInfo
    end.

-spec remove_socket(socket(), close_connection_local | close_connection_remote, #state{}) -> #state{}.
remove_socket(Socket, StatsCloseType, S = #state{config=#config{ssl=Ssl}, free=Free}) ->
    lhttpc_stats:record(StatsCloseType, Socket),
    lhttpc_sock:close(Socket, Ssl),
    S#state{free=drop_and_cancel(Socket,Free)}.

-spec drop_and_cancel(socket(), list(conn_free())) -> list(conn_free()).
drop_and_cancel(_, []) -> [];
drop_and_cancel(Socket, [#conn_free{socket=Socket, timer_ref=TimerRef} | Rest]) ->
    cancel_timer(TimerRef, Socket),
    Rest;
drop_and_cancel(Socket, [H|T]) ->
    [H | drop_and_cancel(Socket, T)].

-spec cancel_timer(reference(), socket()) -> ok.
cancel_timer(undefined, _Socket) -> ok;
cancel_timer(TimerRef, Socket) ->
    case erlang:cancel_timer(TimerRef) of
        false ->
            receive
                {timeout, Socket} -> ok
            after 0 -> ok
            end;
        _ -> ok
    end.

-spec start_timer(socket(), connection_timeout()) -> reference() | 'undefined'.
start_timer(_, infinity) -> 'undefined';
start_timer(Socket, Timeout) ->
    erlang:send_after(Timeout, self(), {timeout,Socket}).

request_limit_reached(_, #config{request_limit=infinity}) ->
    false;
request_limit_reached(#conn_info{request_count=RequestCount}, #config{request_limit=RequestLimit})
  when is_integer(RequestLimit) ->
    RequestCount >= RequestLimit.

expire_time_reached(#conn_info{expire=undefined}) ->
    false;
expire_time_reached(#conn_info{expire=Expire}) when is_integer(Expire) ->
    erlang:monotonic_time() > Expire.

noreply_maybe_shutdown(S=#state{clients=Tid, free=Free}) ->
    case Free =:= [] andalso ets:info(Tid, size) =:= 0 of
        true -> % we're done for
            {noreply,S,?SHUTDOWN_DELAY};
        false ->
            {noreply, S}
    end.
