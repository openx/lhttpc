%%% ----------------------------------------------------------------------------
%%% Copyright (c) 2009, Erlang Training and Consulting Ltd.
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%    * Redistributions of source code must retain the above copyright
%%%      notice, this list of conditions and the following disclaimer.
%%%    * Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%    * Neither the name of Erlang Training and Consulting Ltd. nor the
%%%      names of its contributors may be used to endorse or promote products
%%%      derived from this software without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY Erlang Training and Consulting Ltd. ''AS IS''
%%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL Erlang Training and Consulting Ltd. BE
%%% LIABLE SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
%%% BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
%%% OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
%%% ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%% ----------------------------------------------------------------------------

%%% @author Oscar Hellström <oscar@hellstrom.st>
%%% @doc Connection manager for the HTTP client.
%%% This gen_server is responsible for keeping track of persistent
%%% connections to HTTP servers. The only interesting API is
%%% `connection_count/0' and `connection_count/1'.
%%% The gen_server is supposed to be started by a supervisor, which is
%%% normally {@link lhttpc_sup}.
%%% @end
%%% @type boolean() = bool().
-module(lhttpc_manager).

-export([
        start_link/0
    ]).
-export([
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        code_change/3,
        terminate/2
    ]).

-behaviour(gen_server).

-record(httpc_man, {
        destinations = dict:new()
    }).

%% @spec () -> {ok, pid()}
%% @doc Starts and link to the gen server.
%% This is normally called by a supervisor.
%% @end
-spec start_link() -> {ok, pid()} | {error, allready_started}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, nil, []).

%% @hidden
-spec init(any()) -> {ok, #httpc_man{}}.
init(_) ->
    process_flag(priority, high),
    {ok, #httpc_man{}}.

%% @hidden
-spec handle_call(any(), any(), #httpc_man{}) ->
    {reply, any(), #httpc_man{}}.
handle_call({lb, Host, Port, Ssl}, _, State) ->
    {Reply, NewState} = find_lb({Host, Port, Ssl}, State),
    {reply, Reply, NewState};
handle_call(_, _, State) ->
    {reply, {error, unknown_request}, State}.

%% @hidden
-spec handle_cast(any(), #httpc_man{}) -> {noreply, #httpc_man{}}.
handle_cast(_, State) ->
    {noreply, State}.

%% @hidden
-spec handle_info(any(), #httpc_man{}) -> {noreply, #httpc_man{}}.
handle_info(_, State) ->
    {noreply, State}.

%% @hidden
-spec terminate(any(), #httpc_man{}) -> ok.
terminate(_, State) ->
    close_lbs(State#httpc_man.destinations).

%% @hidden
-spec code_change(any(), #httpc_man{}, any()) -> #httpc_man{}.
code_change(_, State, _) ->
    State.

find_lb(Dest, State) ->
    Dests = State#httpc_man.destinations,
    case dict:find(Dest, Dests) of
        {ok, Lb} ->
            {{ok, Lb}, State};
        error ->
            {ok, Pid} = lhttpc_lb:start_link(Dest),
            NewState = State#httpc_man{
                destinations = update_dest(Dest, Pid, Dests)
            },
            {{ok, Pid}, NewState}
    end.

update_dest(Destination, Lb, Destinations) ->
    dict:store(Destination, Lb, Destinations).

close_lbs(Destinations) ->
    lists:foreach(fun({_Dest, Lb}) ->
        gen_server:cast(Lb, {terminate})
    end, dict:to_list(Destinations)).