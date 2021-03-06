% This file is licensed to you under the Apache License,
% Version 2.0 (the "License"); you may not use this file
% except in compliance with the License.  You may obtain
% a copy of the License at
%
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing,
% software distributed under the License is distributed on an
% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
% KIND, either express or implied.  See the License for the
% specific language governing permissions and limitations
% under the License.
%%% @author Felipe Ripoll <ferigis@gmail.com>
%%% @doc Decorator over {@link gen_fsm} that lets {@link wpool_pool}
%%%      control certain aspects of the execution
-module(wpool_fsm_process).
-author('ferigis@gmail.com').

-behaviour(gen_fsm).

-record(state, {name    :: atom(),
  mod     :: atom(),
  state   :: term(),
  options :: [{time_checker|queue_manager, atom()}
  | wpool:option()],
  born = os:timestamp() :: erlang:timestamp(),
  fsm_state :: fsm_state()
}).
-type state()     :: #state{}.
-type fsm_state() :: atom().
-type from() :: {pid(), reference()}.

%% api
-export([start_link/4, send_event/2,
  sync_send_event/2, sync_send_event/3,
  send_all_state_event/2,
  sync_send_all_state_event/2, sync_send_all_state_event/3,
  age/1]).

%% gen_fsm states
-export([dispatch_state/2, dispatch_state/3]).

%% gen_fsm callbacks
-export([init/1, terminate/3, code_change/4,
  handle_info/3, handle_event/3, handle_sync_event/4, format_status/2]).

%%%===================================================================
%%% API
%%%===================================================================
%% @doc Starts a named process
-spec start_link(wpool:name(), module(), term(), [wpool:option()]) ->
  {ok, pid()} | ignore | {error, {already_started, pid()} | term()}.
start_link(Name, Module, InitArgs, Options) ->
  WorkerOpt = proplists:get_value(worker_opt, Options, []),
  gen_fsm:start_link(
    {local, Name}, ?MODULE, {Name, Module, InitArgs, Options}, WorkerOpt).

-spec send_event(wpool:name() | pid(), term()) -> term().
send_event(Process, Event) ->
  gen_fsm:send_event(Process, Event).

-spec sync_send_event(wpool:name() | pid(), term()) -> term().
sync_send_event(Process, Event) ->
  gen_fsm:sync_send_event(Process, Event).

-spec sync_send_event(wpool:name() | pid(), term(), timeout()) -> term().
sync_send_event(Process, Event, Timeout) ->
  gen_fsm:sync_send_event(Process, Event, Timeout).

-spec send_all_state_event(wpool:name() | pid(), term()) -> term().
send_all_state_event(Process, Event) ->
  gen_fsm:send_all_state_event(Process, Event).

-spec sync_send_all_state_event(wpool:name() | pid(), term()) -> term().
sync_send_all_state_event(Process, Event) ->
  gen_fsm:sync_send_all_state_event(Process, Event).

-spec sync_send_all_state_event(wpool:name() | pid()
                                , term()
                                , timeout()) -> term().
sync_send_all_state_event(Process, Event, Timeout) ->
  gen_fsm:sync_send_all_state_event(Process, Event, Timeout).

%% @doc Report how old a process is in <b>microseconds</b>
-spec age(wpool:name() | pid()) -> non_neg_integer().
age(Process) -> gen_fsm:sync_send_all_state_event(Process, age).

%%%===================================================================
%%% init, terminate, code_change, info callbacks
%%%===================================================================
%% @private
-spec init({atom(), atom(), term(), [wpool:option()]}) ->
  {ok, dispatch_state, state()}.
init({Name, Mod, InitArgs, Options}) ->
  case Mod:init(InitArgs) of
    {ok, FirstState, StateData} ->
      ok = notify_queue_manager(new_worker, Name, Options),
      {ok, dispatch_state, #state{ name = Name
                              , mod = Mod
                              , state = StateData
                              , options = Options
                              , fsm_state = FirstState}};
    {ok, FirstState, StateData, Timeout} ->
      ok = notify_queue_manager(new_worker, Name, Options),
      {ok, dispatch_state, #state{ name = Name
                              , mod = Mod
                              , state = StateData
                              , options = Options
                              , fsm_state = FirstState}, Timeout};
    ignore -> {stop, can_not_ignore};
    Error -> Error
  end.

%% @private
-spec terminate(atom(), fsm_state(), state()) -> term().
terminate(Reason,
    CurrentState,
    #state{mod=Mod, state=Mod_State, name=Name, options=Options}) ->
  ok = notify_queue_manager(worker_dead, Name, Options),
  Mod:terminate(Reason, CurrentState, Mod_State).

%% @private
-spec code_change(string(), fsm_state(), state(), any()) ->
  {ok, dispatch_state, state()}.
code_change(OldVsn, StateName, State, Extra) ->
  case (State#state.mod):code_change(OldVsn, StateName,
                                    State#state.state, Extra) of
    {ok, NextStateName, NewState} ->
      {ok, dispatch_state, State#state{state = NewState,
                                      fsm_state = NextStateName}};
    Error -> {error, Error}
  end.

%% @private
-spec handle_info(any(), fsm_state(), state()) ->
  {next_state, dispatch_state, state()} | {stop, term(), state()}.
handle_info(Info, StateName, StateData) ->
  try (StateData#state.mod):handle_info(Info, StateName,
                                        StateData#state.state) of
    {next_state, NextStateName, NewStateData} ->
      {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                  fsm_state = NextStateName}};
    {next_state, NextStateName, NewStateData, Timeout} ->
      {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                  fsm_state = NextStateName}
                                                  , Timeout};
    {stop, Reason, NewStateData} ->
      {stop, Reason, StateData#state{state = NewStateData}}
  catch
    _:{next_state, NextStateName, NewStateData} ->
      {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                  fsm_state = NextStateName}};
    _:{next_state, NextStateName, NewStateData, Timeout} ->
      {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                  fsm_state = NextStateName}
                                                  , Timeout};
    _:{stop, Reason, NewStateData} ->
      {stop, Reason, StateData#state{state = NewStateData}}
  end.

-spec format_status(normal | terminate, list()) -> term().
format_status(Opt, [PDict, StateData]) ->
  (StateData#state.mod):format_status(Opt, [PDict, StateData#state.state]).

%%%===================================================================
%%% real (i.e. interesting) callbacks
%%%===================================================================
-spec handle_event(term(), fsm_state(), state()) ->
  {next_state, dispatch_state, state()} | {stop, term(), state()}.
handle_event(Event, _StateName, StateData) ->
  Task =
    task_init(
      {handle_event, Event},
      proplists:get_value(time_checker, StateData#state.options, undefined),
      proplists:get_value(overrun_warning, StateData#state.options, infinity)),
  ok = notify_queue_manager(worker_busy,
                            StateData#state.name,
                            StateData#state.options),
  Reply =
    try (StateData#state.mod):handle_event(Event,
              StateData#state.fsm_state, StateData#state.state) of
      {next_state, NextStateName, NewStateData} ->
        {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                    fsm_state = NextStateName}};
      {next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                    fsm_state = NextStateName}
                                                    , Timeout};
      {stop, Reason, NewState} ->
        {stop, Reason, StateData#state{state = NewState}}
    catch
      _:{next_state, NextStateName, NewStateData} ->
        {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                    fsm_state = NextStateName}};
      _:{next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{state = NewStateData,
                                                    fsm_state = NextStateName}
                                                    , Timeout};
      _:{stop, Reason, NewState} ->
        {stop, Reason, StateData#state{state = NewState}}
    end,
  task_end(Task),
  ok =
    notify_queue_manager(worker_ready,
                        StateData#state.name,
                        StateData#state.options),
  Reply.

-spec handle_sync_event(term(), from(), fsm_state(), state()) ->
  {reply, term(), dispatch_state, state()}
  | {next_state, dispatch_state, state()}
  | {stop, term(), state()}.
handle_sync_event(age, _From, _StateName, #state{born=Born} = State) ->
  {reply, timer:now_diff(os:timestamp(), Born), dispatch_state, State};
handle_sync_event(Event, From, _StateName, StateData) ->
  Task =
    task_init(
      {handle_sync_event, Event},
      proplists:get_value(time_checker, StateData#state.options, undefined),
      proplists:get_value(overrun_warning, StateData#state.options, infinity)),
  ok = notify_queue_manager(worker_busy,
                            StateData#state.name,
                            StateData#state.options),
  Result =
    try (StateData#state.mod):handle_sync_event(Event, From,
              StateData#state.fsm_state, StateData#state.state) of
      {reply, Reply, NextStateName, NewStateData} ->
        {reply, Reply, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}};
      {reply, Reply, NextStateName, NewStateData, Timeout} ->
        {reply, Reply, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}
                                        , Timeout};
      {next_state, NextStateName, NewStateData} ->
        {next_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}};
      {next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}
                                        , Timeout};
      {stop, Reason, NewState} ->
        {stop, Reason, StateData#state{state = NewState}};
      {stop, Reason, Response, NewState} ->
        {stop, Reason, Response, StateData#state{state = NewState}}
    catch
      _:{reply, Reply, NextStateName, NewStateData} ->
        {reply, Reply, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}};
      _:{reply, Reply, NextStateName, NewStateData, Timeout} ->
        {reply, Reply, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}
                                        , Timeout};
      _:{next_state, NextStateName, NewStateData} ->
        {next_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}};
      _:{next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}
                                        , Timeout};
      _:{stop, Reason, NewState} ->
        {stop, Reason, StateData#state{state = NewState}};
      _:{stop, Reason, Response, NewState} ->
        {stop, Reason, Response, StateData#state{state = NewState}}
    end,
  task_end(Task),
  ok =
    notify_queue_manager(worker_ready,
                        StateData#state.name,
                        StateData#state.options),
  Result.

%%%===================================================================
%%% FSM States
%%%===================================================================
-spec dispatch_state(term(), state()) ->
  {next_state, dispatch_state, state()} | {stop, term(), state()}.
dispatch_state(Event, StateData) ->
  Task = get_task(Event, StateData),
  ok = notify_queue_manager(worker_busy,
                            StateData#state.name,
                            StateData#state.options),
  Reply =
    try (StateData#state.mod):(StateData#state.fsm_state)(Event,
                                            StateData#state.state) of
      {next_state, NextStateName, NewStateData}  ->
        {next_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}};
      {next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}
                                        , Timeout};
      {stop, Reason, NewStateData} ->
        {stop, Reason, StateData#state{state = NewStateData}}
    catch
      _:{next_state, NextStateName, NewStateData}  ->
        {rnext_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}};
      _:{next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{
                                        state = NewStateData,
                                        fsm_state = NextStateName}
                                        , Timeout};
      _:{stop, Reason, NewStateData} ->
        {stop, Reason, StateData#state{state = NewStateData}}
    end,
  task_end(Task),
  ok =
    notify_queue_manager(worker_ready,
                        StateData#state.name,
                        StateData#state.options),
  Reply.

-spec dispatch_state(term(), from(), state()) ->
                          {reply, term(), dispatch_state, state()}
                          | {next_state, dispatch_state, state()}
                          | {stop, term(), state()}.
dispatch_state(Event, From, StateData) ->
  Task = get_task(Event, StateData),
  ok = notify_queue_manager(worker_busy,
                            StateData#state.name,
                            StateData#state.options),
  Result =
    try (StateData#state.mod):(StateData#state.fsm_state)(Event,
                                  From, StateData#state.state) of
      {reply, Reply, NextStateName, NewStateData} ->
        {reply, Reply, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}};
      {reply, Reply, NextStateName, NewStateData, Timeout} ->
        {reply, Reply, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}
                                          , Timeout};
      {next_state, NextStateName, NewStateData}  ->
        {next_state, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}};
      {next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}
                                          , Timeout};
      {stop, Reason, NewStateData} ->
        {stop, Reason, StateData#state{state = NewStateData}};
      {stop, Reason, Reply, NewStateData} ->
        {stop, Reason, Reply, StateData#state{state = NewStateData}}
    catch
      _:{reply, Reply, NextStateName, NewStateData} ->
        {reply, Reply, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}};
      _:{reply, Reply, NextStateName, NewStateData, Timeout} ->
        {reply, Reply, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}
                                          , Timeout};
      _:{next_state, NextStateName, NewStateData}  ->
        {next_state, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}};
      _:{next_state, NextStateName, NewStateData, Timeout} ->
        {next_state, dispatch_state, StateData#state{
                                          state = NewStateData,
                                          fsm_state = NextStateName}
                                          , Timeout};
      _:{stop, Reason, NewStateData} ->
        {stop, Reason, StateData#state{state = NewStateData}};
      _:{stop, Reason, Reply, NewStateData} ->
        {stop, Reason, Reply, StateData#state{state = NewStateData}}
    end,
  task_end(Task),
  ok =
    notify_queue_manager(worker_ready,
                        StateData#state.name,
                        StateData#state.options),
  Result.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% PRIVATE FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Marks Task as started in this worker
-spec task_init(term(), atom(), infinity | pos_integer()) ->
  undefined | reference().
task_init(Task, _TimeChecker, infinity) ->
  Time = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
  erlang:put(wpool_task, {undefined, Time, Task}),
  undefined;
task_init(Task, TimeChecker, OverrunTime) ->
  TaskId = erlang:make_ref(),
  Time = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
  erlang:put(wpool_task, {TaskId, Time, Task}),
  erlang:send_after(
    OverrunTime, TimeChecker, {check, self(), TaskId, OverrunTime}).

%% @doc Removes the current task from the worker
-spec task_end(undefined | reference()) -> ok.
task_end(undefined) -> erlang:erase(wpool_task);
task_end(TimerRef) ->
  _ = erlang:cancel_timer(TimerRef),
  erlang:erase(wpool_task).

notify_queue_manager(Function, Name, Options) ->
  case proplists:get_value(queue_manager, Options) of
    undefined -> ok;
    QueueManager -> wpool_queue_manager:Function(QueueManager, Name)
  end.

get_task(Event, StateData) ->
  task_init(
    {dispatch_state, Event},
    proplists:get_value(time_checker, StateData#state.options, undefined),
    proplists:get_value(overrun_warning, StateData#state.options, infinity)).
