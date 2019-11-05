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

-type header() :: {string() | atom(), string()}.
-type headers() :: [header()].

-type socket() :: _.

-type stats_fun() :: fun(('normal'|'timeout'|'error', non_neg_integer()) -> term()).

-type option() ::
        {connect_options, list()} |
        {connect_timeout, timeout()} |
        {connection_timeout, non_neg_integer() | infinity} |
        {connection_lifetime, non_neg_integer() | infinity} |
        {request_limit, non_neg_integer() | infinity} |
        {max_connections, non_neg_integer()} |
        {send_retry, non_neg_integer()} |
        {stream_to, pid()} |
        {stats_fun, stats_fun()} |
        {partial_upload, non_neg_integer() | infinity} |
        {partial_download, list({window_size, integer()} |
                                {part_size, integer() | infinity})}.

-type options() :: [option()].

-type host() :: string() | {integer(), integer(), integer(), integer()}.

-type socket_options() :: [{atom(), term()} | atom()].

-type window_size() :: non_neg_integer() | infinity.

-record(lhttpc_stats_state, {stats_fun :: stats_fun(), start_time :: integer()}).
-type lhttpc_stats_state() :: #lhttpc_stats_state{} | 'undefined'.
