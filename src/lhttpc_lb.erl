%%% Load balancer for lhttpc, replacing the older lhttpc_manager.
%%% Takes a similar stance of storing used-but-not-closed sockets.
%%% Also adds functionality to limit the number of simultaneous
%%% connection attempts from clients.
-module(lhttpc_lb).
-behaviour(gen_server).
-export([start_link/1, checkout/7, checkin/4, connection_count/3, connection_count/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-define(SHUTDOWN_DELAY, 10000).

%% TODO: transfert_socket, in case of checkout+give_away

-record(config,
        {host :: host(),
         port :: port_number(),
         ssl :: boolean(),
         max_conn :: max_connections(),
         timeout :: timeout(),
         request_limit :: request_limit(),
         conn_lifetime :: connection_lifetime()}).

-record(conn_info,
        {request_count = 0 :: non_neg_integer(),
         expire :: integer() | undefined}).

-record(conn_free,
        {socket :: socket(),
         timer_ref :: reference(),
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
        {ok, socket()} | retry_later | no_socket.
checkout(Host, Port, Ssl, MaxConn, ConnTimeout, RequestLimit, ConnLifetime) ->
    Config = #config{host = Host, port = Port, ssl = Ssl,
                     max_conn = MaxConn, timeout = ConnTimeout,
                     request_limit = RequestLimit, conn_lifetime = ConnLifetime},
    Lb = find_or_start_lb(Config),
    gen_server:call(Lb, {checkout, self()}, infinity).

%% Called when we're done and the socket can still be reused
-spec checkin(host(), port_number(), SSL::boolean(), Socket::socket()) -> ok.
checkin(Host, Port, Ssl, Socket) ->
    case find_lb({Host,Port,Ssl}) of
        {error, undefined} ->
            %% should we close the socket? We're not keeping it! There are no
            %% Lbs available!
            ok;
        {ok, Pid} ->
            %% Give ownership back to the server ASAP. The client has to have
            %% kept the socket passive. We rely on its good behaviour.
            %% If the transfer doesn't work, we don't notify.
            case lhttpc_sock:controlling_process(Socket, Pid, Ssl) of
                ok -> gen_server:cast(Pid, {checkin, self(), Socket});
                _ -> ok
            end
    end.

%% Returns a tuple with the number of active (currently in use) and
%% the number of idle (open but not currently in use) connections for
%% the host, port, and SSL state.
-spec connection_count(host(), port_number(), Ssl::boolean()) ->
                       {ActiveConnections::integer(), IdleConnections::integer()}.
connection_count(Host, Port, Ssl) ->
    connection_count({Host, Port, Ssl}).

connection_count(Name) ->
    case find_lb(Name) of
        {error, undefined} -> {0, 0};
        {ok, Pid} -> gen_server:call(Pid, {connection_count})
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init(Config=#config{host=Host, port=Port, ssl=Ssl}) ->
    %% Write host config to process dictionary so that it can be fetched with
    %% `process_info(Pid, dictionary)'.
    put(lhttpc_lb_host, {Host, Port, Ssl}),

    %% we must use insert_new because it is possible a concurrent request is
    %% starting such a server at exactly the same time.
    case ets:insert_new(?MODULE, {{Host,Port,Ssl}, self()}) of
        true ->
            {ok, #state{config=Config,
                        clients=ets:new(clients, [set, private])}};
        false ->
            ignore
    end.

handle_call({checkout,Pid}, _From, S = #state{free=[], clients=Tid, config=Config}) ->
    Size = ets:info(Tid, size),
    case Config#config.max_conn > Size of
        true ->
            %% We don't have an open socket, but the client can open one.
            Expire =
                case Config#config.conn_lifetime of
                    infinity     -> undefined;
                    ConnLifetime -> erlang:monotonic_time() + erlang:convert_time_unit(ConnLifetime, milli_seconds, native)
                end,
            add_client(Tid, Pid, #conn_info{request_count = 1, expire = Expire}),
            {reply, no_socket, S};
        false ->
            {reply, retry_later, S}
    end;
handle_call({checkout,Pid}, _From,
            S=#state{free=[#conn_free{socket=Taken, timer_ref=Timer, conn_info=ConnInfo} | Free], clients=Tid, config=#config{ssl=Ssl}}) ->
    lhttpc_sock:setopts(Taken, [{active,false}], Ssl),
    case lhttpc_sock:controlling_process(Taken, Pid, Ssl) of
        ok ->
            cancel_timer(Timer, Taken),
            add_client(Tid, Pid, ConnInfo#conn_info{request_count = ConnInfo#conn_info.request_count + 1}),
            {reply, {ok, Taken}, S#state{free=Free}};
        {error, badarg} ->
            %% The caller died.
            lhttpc_sock:setopts(Taken, [{active, once}], Ssl),
            {noreply, S};
        {error, _Reason} -> % socket is closed or something
            cancel_timer(Timer, Taken),
            handle_call({checkout,Pid}, _From, S#state{free=Free})
    end;
handle_call({connection_count}, _From, S = #state{free=Free, clients=Tid}) ->
    {reply, {ets:info(Tid, size), length(Free)}, S};

handle_call(_Msg, _From, S) ->
    {noreply, S}.

handle_cast({checkin, Pid, Socket}, S = #state{config=Config=#config{ssl=Ssl, timeout=T}, clients=Tid, free=Free}) ->
    lhttpc_stats:record(end_request, Socket),
    ConnInfo = remove_client(Tid, Pid),
    case
        ConnInfo =:= undefined orelse
        request_limit_reached(ConnInfo, Config) orelse
        expire_time_reached(ConnInfo) orelse
        %% the client cast function took care of giving us ownership
        %% Set {active, once} so that we will get a message if the remote closes the socket.
        lhttpc_sock:setopts(Socket, [{active, once}], Ssl) =/= ok % socket closed or failed
    of
        true ->
            noreply_maybe_shutdown(remove_socket(Socket, S));
        false ->
            Timer = start_timer(Socket,T),
            {noreply, S#state{free=[#conn_free{socket = Socket, timer_ref = Timer, conn_info = ConnInfo} | Free]}}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, S=#state{clients=Tid}) ->
    %% Client died
    case Reason of
        normal      -> ok;
        noproc      -> ok; %% A client made a request but died before we could start monitoring it.
        timeout     -> lhttpc_stats:record(close_connection_timeout, Pid);
        OtherReason -> io:format(standard_error, "DOWN ~p\n", [ OtherReason ])
    end,
    remove_client(Tid,Pid),
    noreply_maybe_shutdown(S);
handle_info({tcp_closed, Socket}, State) ->
    noreply_maybe_shutdown(remove_socket(Socket,State));
handle_info({ssl_closed, Socket}, State) ->
    noreply_maybe_shutdown(remove_socket(Socket,State));
handle_info({timeout, Socket}, State) ->
    noreply_maybe_shutdown(remove_socket(Socket,State));
handle_info({tcp_error, Socket, _}, State) ->
    noreply_maybe_shutdown(remove_socket(Socket,State));
handle_info({ssl_error, Socket, _}, State) ->
    noreply_maybe_shutdown(remove_socket(Socket,State));
handle_info({tcp, Socket, _}, State) ->
    noreply_maybe_shutdown(remove_socket(Socket,State));
handle_info({ssl, Socket, _}, State) ->
    noreply_maybe_shutdown(remove_socket(Socket,State));
handle_info(timeout, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{config=#config{host=H, port=P, ssl=Ssl}, free=Free, clients=Tid}) ->
    ets:delete(Tid),
    ets:delete(?MODULE,{H,P,Ssl}),
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
find_or_start_lb(Config=#config{host=Host, port=Port, ssl=Ssl}) ->
    Name = {Host, Port, Ssl},
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
-spec find_lb(Name::{host(),port_number(),boolean()}) -> {error,undefined} | {ok,pid()}.
find_lb(Name={_Host,_Port,_Ssl}) ->
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

-spec remove_client(ets:tid(), pid()) -> conn_info() | undefined.
remove_client(Tid, Pid) ->
    case ets:lookup(Tid, Pid) of
        [] -> undefined; % client already removed
        [{_Pid, Ref, ConnInfo}] ->
            erlang:demonitor(Ref, [flush]),
            ets:delete(Tid, Pid),
            ConnInfo
    end.

-spec remove_socket(socket(), #state{}) -> #state{}.
remove_socket(Socket, S = #state{config=#config{ssl=Ssl}, free=Free}) ->
    lhttpc_stats:record(close_connection_local, Socket),
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
cancel_timer(TimerRef, Socket) ->
    case erlang:cancel_timer(TimerRef) of
        false ->
            receive
                {timeout, Socket} -> ok
            after 0 -> ok
            end;
        _ -> ok
    end.

-spec start_timer(socket(), connection_timeout()) -> reference().
start_timer(_, infinity) -> make_ref(); % dummy timer
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
