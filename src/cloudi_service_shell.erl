%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Shell Service==
%%% For ensuring each shell command-line is executed correctly,
%%% it is best to keep the interactive argument set to false (the default)
%%% so each service request uses its own shell.
%%%
%%% Use the interactive argument if you need to utilize a programming
%%% language interpreter.  For example, SBCL could be used with
%%% ``exec /usr/bin/sbcl --noinform --disable-debugger --eval '(setf sb-int:*repl-prompt-fun* (lambda (stream) (format stream \"~&\")))' ''
%%% and Python could be used with
%%% ``exec /usr/bin/python3 -ui -c 'import sys; sys.ps1 = sys.ps2 = \"\"'''.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2019-2025 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2019-2025 Michael Truog
%%% @version 2.0.8 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_shell).
-author('mjtruog at protonmail dot com').

-behaviour(cloudi_service).

%% external interface
-export([exec/3,
         exec/4,
         validate_response/2]).

%% cloudi_service callbacks
-export([cloudi_service_init/4,
         cloudi_service_handle_request/11,
         cloudi_service_handle_info/3,
         cloudi_service_terminate/3]).

-include_lib("cloudi_core/include/cloudi_logger.hrl").

-define(DEFAULT_FILE_PATH,                    "/bin/sh").
-define(DEFAULT_DIRECTORY,                          "/").
-define(DEFAULT_ENV,                                 []).
-define(DEFAULT_USER,                         undefined).
-define(DEFAULT_SU_PATH,                      "/bin/su").
-define(DEFAULT_LOGIN,                             true).
-define(DEFAULT_INTERACTIVE,                      false).
        % Should a shell for interactive use be created?
        % If set to true, a single shell is used during the
        % service's lifetime with a service request as input
        % to generate a response.  If set to a string,
        % the string is used as initial input to the shell.
        % The shell does not execute as an interactive shell
        % due to not using keyboard input.  If set to false,
        % each service request uses its own shell and the
        % response provides the exit status.
-define(DEFAULT_TIMEOUT_KILLS_PROCESS,            false).
        % A service request timeout should kill the OS shell process?
-define(DEFAULT_TIMEOUT_KILLS_PROCESS_SIGNAL,   sigkill).
        % OS signal to use for OS shell process timeout.
-define(DEFAULT_TERMINATE_KILLS_PROCESS,          false).
        % Service termination should kill the OS shell process?
        % If this argument is false, stdout will still be closed
        % due to the termination of the service
        % (e.g., echo will exit with a failure).
-define(DEFAULT_TERMINATE_KILLS_PROCESS_SIGNAL, sigkill).
        % OS signal to use for OS shell process termination.
-define(DEFAULT_DEBUG,                             true).
-define(DEFAULT_DEBUG_LEVEL,                      trace).

-record(state,
    {
        service :: cloudi_service:source(),
        file_path :: nonempty_string(),
        directory :: nonempty_string(),
        env :: list({nonempty_string(), string()}),
        env_port :: boolean(),
        user :: nonempty_string() | undefined,
        su :: nonempty_string(),
        login :: boolean(),
        interactive = undefined :: port() | undefined,
        kill_signal_timeout :: pos_integer() | undefined,
        kill_signal_terminate :: pos_integer() | undefined,
        debug_level :: off | trace | debug | info | warn | error | fatal
    }).

% avoid misuse of old catch with a macro
-define(CATCH(E),
        try E, ok catch _:_ -> ok end).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

-type agent() :: cloudi:agent().
-type service_name() :: cloudi:service_name().
-type timeout_period() :: cloudi:timeout_period().
-type module_response(Result) ::
    {{ok, Result}, AgentNew :: agent()} |
    {{error, cloudi:error_reason()}, AgentNew :: agent()}.

-spec exec(Agent :: agent(),
           Prefix :: service_name(),
           Command :: nonempty_string() | binary()) ->
    module_response(binary()).

exec(Agent, Prefix, Command) ->
    cloudi:send_sync(Agent, Prefix, Command).

-spec exec(Agent :: agent(),
           Prefix :: service_name(),
           Command :: nonempty_string() | binary(),
           Timeout :: timeout_period()) ->
    module_response(binary()).

exec(Agent, Prefix, Command, Timeout) ->
    cloudi:send_sync(Agent, Prefix, Command, Timeout).

-spec validate_response(cloudi_service:response_info(),
                        Response :: cloudi_service:response()) ->
    boolean().

validate_response(_, Response) ->
    erlang:binary_to_integer(Response) == 0.

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_service
%%%------------------------------------------------------------------------

cloudi_service_init(Args, _Prefix, _Timeout, Dispatcher) ->
    Defaults = [
        {file_path,                     ?DEFAULT_FILE_PATH},
        {directory,                     ?DEFAULT_DIRECTORY},
        {env,                           ?DEFAULT_ENV},
        {user,                          ?DEFAULT_USER},
        {su_path,                       ?DEFAULT_SU_PATH},
        {login,                         ?DEFAULT_LOGIN},
        {interactive,                   ?DEFAULT_INTERACTIVE},
        {timeout_kills_process,         ?DEFAULT_TIMEOUT_KILLS_PROCESS},
        {timeout_kills_process_signal,  ?DEFAULT_TIMEOUT_KILLS_PROCESS_SIGNAL},
        {terminate_kills_process,       ?DEFAULT_TERMINATE_KILLS_PROCESS},
        {terminate_kills_process_signal,?DEFAULT_TERMINATE_KILLS_PROCESS_SIGNAL},
        {debug,                         ?DEFAULT_DEBUG},
        {debug_level,                   ?DEFAULT_DEBUG_LEVEL}],
    [FilePath, Directory, Env, User, SUPath, Login, Interactive,
     TimeoutKill, TimeoutKillSignal,
     TerminateKill, TerminateKillSignal,
     Debug, DebugLevel] = cloudi_proplists:take_values(Defaults, Args),
    Service = cloudi_service:self(Dispatcher),
    [_ | _] = FilePath,
    true = filelib:is_regular(FilePath),
    [_ | _] = Directory,
    true = filelib:is_dir(Directory),
    EnvExpanded = env_expand(Env, cloudi_environment:lookup()),
    case User of
        undefined ->
            ok;
        [_ | _] ->
            true = filelib:is_regular(SUPath)
    end,
    EnvPort = if
        Login =:= true, is_list(User) ->
            false;
        is_boolean(Login) ->
            true
    end,
    true = is_boolean(Interactive) orelse
           (is_list(Interactive) andalso is_integer(hd(Interactive))),
    EnvExpanded = env_expand(Env, cloudi_environment:lookup()),
    EnvShell = if
        EnvPort =:= true ->
            env_reset(EnvExpanded);
        EnvPort =:= false ->
            EnvExpanded
    end,
    KillSignalTimeout = if
        TimeoutKill =:= true ->
            cloudi_os_process:signal_to_integer(TimeoutKillSignal);
        TimeoutKill =:= false ->
            undefined
    end,
    KillSignalTerminate = if
        TerminateKill =:= true ->
            cloudi_os_process:signal_to_integer(TerminateKillSignal);
        TerminateKill =:= false ->
            undefined
    end,
    true = is_boolean(Debug),
    true = ((DebugLevel =:= trace) orelse
            (DebugLevel =:= debug) orelse
            (DebugLevel =:= info) orelse
            (DebugLevel =:= warn) orelse
            (DebugLevel =:= error) orelse
            (DebugLevel =:= fatal)),
    DebugLogLevel = if
        Debug =:= false ->
            off;
        Debug =:= true ->
            DebugLevel
    end,
    State = interactive_init(Interactive,
                             #state{service = Service,
                                    file_path = FilePath,
                                    directory = Directory,
                                    env = EnvShell,
                                    env_port = EnvPort,
                                    user = User,
                                    su = SUPath,
                                    login = Login,
                                    kill_signal_timeout = KillSignalTimeout,
                                    kill_signal_terminate = KillSignalTerminate,
                                    debug_level = DebugLogLevel}),
    cloudi_service:subscribe(Dispatcher, ""),
    {ok, State}.

cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              RequestInfo, Request,
                              Timeout, _Priority, _TransId, _Source,
                              #state{interactive = undefined,
                                     debug_level = DebugLogLevel} = State,
                              _Dispatcher) ->
    {Status, Output} = isolated_request(Request, Timeout, State),
    ok = isolated_log_output(Status, Output,
                             RequestInfo, Request, DebugLogLevel),
    {reply, erlang:integer_to_binary(Status), State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              RequestInfo, Request,
                              Timeout, _Priority, _TransId, _Source,
                              #state{interactive = Shell,
                                     debug_level = DebugLogLevel} = State,
                              _Dispatcher)
    when is_port(Shell) ->
    Output = interactive_request(Request, Timeout, State),
    ok = interactive_log_output(Output, RequestInfo, Request, DebugLogLevel),
    {reply, erlang:iolist_to_binary(Output), State}.

cloudi_service_handle_info({Shell, {data, Data}},
                           #state{interactive = Shell,
                                  debug_level = DebugLogLevel} = State,
                           _Dispatcher) ->
    ok = interactive_log_output(Data, DebugLogLevel),
    {noreply, State};
cloudi_service_handle_info({Shell, {exit_status, Status} = Reason},
                           #state{interactive = Shell,
                                  debug_level = DebugLogLevel} = State,
                           _Dispatcher) ->
    ok = interactive_log_exit(Status, DebugLogLevel),
    {stop, Reason, State}.

cloudi_service_terminate(_Reason, _Timeout,
                         #state{interactive = Shell}) ->
    if
        Shell =:= undefined ->
            ok;
        is_port(Shell) ->
            ?CATCH(erlang:port_close(Shell))
    end,
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

env_expand([] = L, _) ->
    L;
env_expand([{[_ | _] = Key, Value} | L], Lookup)
    when is_list(Value) ->
    [_ | _] = KeyExpanded = cloudi_environment:transform(Key, Lookup),
    [{KeyExpanded, cloudi_environment:transform(Value, Lookup)} |
     env_expand(L, Lookup)].

env_reset(L) ->
    % remove environment variables set by CloudI execution
    [{"BINDIR", false},
     {"EMU", false},
     {"ERL_AFLAGS", false},
     {"ERL_COMPILER_OPTIONS", false},
     {"ERL_CRASH_DUMP", false},
     {"ERL_CRASH_DUMP_SECONDS", false},
     {"ERL_EPMD_ADDRESS", false},
     {"ERL_EPMD_PORT", false},
     {"ERL_FLAGS", false},
     {"ERL_LIBS", false},
     {"ERL_ZFLAGS", false},
     {"ESCRIPT_NAME", false},
     {"HEART_BEAT_TIMEOUT", false},
     {"HEART_COMMAND", false},
     {"HEART_KILL_SIGNAL", false},
     {"HEART_NO_KILL", false},
     {"PROGNAME", false},
     {"ROOTDIR", false},
     {"RUN_ERL_DISABLE_FLOWCNTRL", false},
     {"RUN_ERL_LOG_ACTIVITY_MINUTES", false},
     {"RUN_ERL_LOG_ALIVE_FORMAT", false},
     {"RUN_ERL_LOG_ALIVE_IN_UTC", false},
     {"RUN_ERL_LOG_ALIVE_MINUTES", false},
     {"RUN_ERL_LOG_GENERATIONS", false},
     {"RUN_ERL_LOG_MAXSIZE", false},
     {"TMPDIR", false} | L].

env_set([], Directory, ShellInput) ->
    [["cd ", Directory, $\n] | ShellInput];
env_set([{[_ | _] = Key, Value} | L], Directory, ShellInput) ->
    [[Key, $=, Value, "; export ", Key, $\n] |
     env_set(L, Directory, ShellInput)].

isolated_request(Exec, Timeout,
                 #state{file_path = FilePath,
                        directory = Directory,
                        env = Env,
                        env_port = EnvPort,
                        user = User,
                        su = SUPath,
                        login = Login,
                        kill_signal_timeout = KillSignalTimeout,
                        kill_signal_terminate = KillSignalTerminate}) ->
    ShellInput0 = [unicode:characters_to_binary(Exec, utf8), "\n"
                  "exit $?\n"],
    {ShellInputN,
     Shell} = shell(ShellInput0, FilePath, Directory, Env, EnvPort,
                    User, SUPath, Login),
    KillOnExit = kill_on_exit_start(KillSignalTerminate),
    KillTimer = kill_timer_start(KillSignalTimeout, Shell, Timeout),
    true = erlang:port_command(Shell, ShellInputN),
    ShellOutput = isolated_request_output(Shell, [], KillSignalTerminate),
    ok = kill_timer_stop(KillTimer, Shell),
    ok = kill_on_exit_stop(KillOnExit),
    ok = ?CATCH(erlang:port_close(Shell)),
    ShellOutput.

isolated_request_output(Shell, Output, KillSignalTerminate) ->
    receive
        {Shell, {data, Data}} ->
            isolated_request_output(Shell, [Data | Output],
                                    KillSignalTerminate);
        {'EXIT', _Service, Reason} ->
            ok = kill_shell(KillSignalTerminate, Shell),
            erlang:exit(Reason),
            isolated_request_output(Shell, Output, KillSignalTerminate);
        {Shell, {kill, KillSignalTimeout}} ->
            true = erlang:unlink(Shell),
            ok = kill_shell(KillSignalTimeout, Shell),
            isolated_request_output(Shell, Output, KillSignalTerminate);
        {Shell, {exit_status, Status}} ->
            {Status, lists:reverse(Output)}
    end.

interactive_init(false, State) ->
    State;
interactive_init(Interactive,
                 #state{file_path = FilePath,
                        directory = Directory,
                        env = Env,
                        env_port = EnvPort,
                        user = User,
                        su = SUPath,
                        login = Login} = State) ->
    ShellInput0 = if
        Interactive =:= true ->
            "";
        is_list(Interactive) ->
            [unicode:characters_to_binary(Interactive, utf8), "\n"]
    end,
    {ShellInputN,
     Shell} = shell(ShellInput0, FilePath, Directory, Env, EnvPort,
                    User, SUPath, Login),
    true = erlang:port_command(Shell, ShellInputN),
    State#state{interactive = Shell}.

interactive_request(Eval, Timeout,
                    #state{service = Service,
                           interactive = Shell,
                           kill_signal_timeout = KillSignalTimeout,
                           kill_signal_terminate = KillSignalTerminate}) ->
    ShellInput = [unicode:characters_to_binary(Eval, utf8), "\n"],
    KillOnExit = kill_on_exit_start(KillSignalTerminate),
    KillTimer = kill_timer_start(KillSignalTimeout, Shell, Timeout),
    true = erlang:port_connect(Shell, self()),
    true = erlang:port_command(Shell, ShellInput),
    Output = interactive_request_output(Shell, [], Timeout + 500,
                                        KillSignalTerminate),
    ok = kill_timer_stop(KillTimer, Shell),
    ok = kill_on_exit_stop(KillOnExit),
    true = erlang:port_connect(Shell, Service),
    true = erlang:unlink(Shell),
    Output.

interactive_request_output(Shell, Output, Timeout, KillSignalTerminate) ->
    receive
        {Shell, {data, Data}} ->
            interactive_request_output(Shell, [Data | Output], 0,
                                       KillSignalTerminate);
        {Shell, connected} ->
            interactive_request_output(Shell, Output, Timeout,
                                       KillSignalTerminate);
        {'EXIT', _Service, Reason} ->
            ok = kill_shell(KillSignalTerminate, Shell),
            erlang:exit(Reason),
            Output;
        {Shell, {kill, KillSignalTimeout}} ->
            ok = kill_shell(KillSignalTimeout, Shell),
            Output
    after
        Timeout ->
            Output
    end.

shell(ShellInput0, FilePath, Directory, Env, EnvPort,
      User, SUPath, Login) ->
    PortOptions0 = [stream, binary, stderr_to_stdout, exit_status],
    {ShellInputN, PortOptionsN} = if
        EnvPort =:= true ->
            {ShellInput0,
             [{env, Env}, {cd, Directory} | PortOptions0]};
        EnvPort =:= false ->
            {env_set(Env, Directory, ShellInput0),
             PortOptions0}
    end,
    {ShellExecutable, ShellArgs} = if
        User =:= undefined ->
            {FilePath,
             if
                 Login =:= true ->
                     ["-"];
                 Login =:= false ->
                     []
             end};
        is_list(User) ->
            {SUPath,
             if
                 Login =:= true ->
                     ["-s", FilePath, "-", User];
                 Login =:= false ->
                     ["-s", FilePath, User]
             end}
    end,
    {ShellInputN,
     erlang:open_port({spawn_executable, ShellExecutable},
                      [{args, ShellArgs} | PortOptionsN])}.

kill_shell(KillSignal, Shell) ->
    case erlang:port_info(Shell, os_pid) of
        undefined ->
            ok;
        {os_pid, OSPid} ->
            _ = cloudi_os_process:kill_group(KillSignal, OSPid),
            ok
    end.

kill_timer_start(undefined, _, _) ->
    undefined;
kill_timer_start(KillSignalTimeout, Shell, Timeout)
    when is_integer(KillSignalTimeout) ->
    erlang:send_after(Timeout, self(), {Shell, {kill, KillSignalTimeout}}).

kill_timer_stop(undefined, _) ->
    ok;
kill_timer_stop(KillTimer, Shell) ->
    case erlang:cancel_timer(KillTimer) of
        false ->
            receive
                {Shell, {kill, _}} ->
                    ok
            after
                0 ->
                    ok
            end;
        _ ->
            ok
    end.

kill_on_exit_start(undefined) ->
    false;
kill_on_exit_start(KillSignalTerminate)
    when is_integer(KillSignalTerminate) ->
    false = erlang:process_flag(trap_exit, true),
    true.

kill_on_exit_stop(false) ->
    ok;
kill_on_exit_stop(true) ->
    true = erlang:process_flag(trap_exit, false),
    ok.

isolated_log_output(Status, Output, RequestInfo, Request, DebugLogLevel) ->
    Level = log_level(Status, DebugLogLevel),
    Info = log_output_info(RequestInfo),
    StatusStr = status_to_string(Status),
    if
        Output == [] ->
            ?LOG(Level, "~ts~ts = ~s",
                 [Info, Request, StatusStr]);
        true ->
            ?LOG(Level, "~ts~ts = ~s (stdout/stderr below)~n~ts",
                 [Info, Request, StatusStr,
                  erlang:iolist_to_binary(Output)])
    end.

interactive_log_output(Output, RequestInfo, Request, DebugLogLevel) ->
    Info = log_output_info(RequestInfo),
    if
        Output == [] ->
            ?LOG(DebugLogLevel, "~ts~ts (no output)",
                 [Info, Request]);
        true ->
            ?LOG(DebugLogLevel, "~ts~ts (stdout/stderr below)~n~ts",
                 [Info, Request,
                  erlang:iolist_to_binary(Output)])
    end.

interactive_log_output(Data, DebugLogLevel) ->
    ?LOG(DebugLogLevel, "~ts", [Data]).

interactive_log_exit(Status, DebugLogLevel) ->
    Level = log_level(Status, DebugLogLevel),
    StatusStr = status_to_string(Status),
    ?LOG(Level, "exit ~s", [StatusStr]).

log_level(0, DebugLogLevel) ->
    DebugLogLevel;
log_level(_, _) ->
    error.

log_output_info(RequestInfo)
    when is_binary(RequestInfo), RequestInfo /= <<>> ->
    InfoTextPairs = cloudi_request_info:key_value_parse(RequestInfo, list),
    erlang:iolist_to_binary(log_output_info_format(InfoTextPairs));
log_output_info(_) ->
    <<"">>.

log_output_info_format([]) ->
    [];
log_output_info_format([{Key, Value} | InfoTextPairs]) ->
    ["# ", Key, ": ", Value, $\n | log_output_info_format(InfoTextPairs)].

status_to_string(Status)
    when Status > 128 ->
    cloudi_os_process:signal_to_string(Status - 128);
status_to_string(Status) ->
    erlang:integer_to_list(Status).

