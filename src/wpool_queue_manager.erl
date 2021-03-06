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
%%% @hidden
-module(wpool_queue_manager).
-author('elbrujohalcon@inaka.net').

-behaviour(gen_server).

%% api
-export([start_link/2]).
-export([call_available_worker/3, cast_to_available_worker/2,
         send_event_to_available_worker/2,
         sync_send_event_to_available_worker/3,
         send_all_event_to_available_worker/2,
         sync_send_all_event_to_available_worker/3,
         new_worker/2, worker_dead/2, worker_ready/2, worker_busy/2]).
-export([pools/0, stats/1, proc_info/1, proc_info/2, trace/1, trace/3]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3,
         handle_call/3, handle_cast/2, handle_info/2]).

-include("wpool.hrl").

-record(state, {wpool                 :: wpool:name(),
                clients               :: queue:queue({cast|{pid(), _}, term()}),
                workers               :: gb_sets:set(atom()),
                born = os:timestamp() :: erlang:timestamp()
               }).
-type state() :: #state{}.

-type queue_mgr() :: atom().
-export_type([queue_mgr/0]).

%%%===================================================================
%%% API
%%%===================================================================
%% @private
-spec start_link(wpool:name(), queue_mgr())
                -> {ok, pid()} | {error, {already_started, pid()} | term()}.
start_link(WPool, Name) ->
  gen_server:start_link({local, Name}, ?MODULE, WPool, []).

%% @doc returns the first available worker in the pool
-spec call_available_worker(queue_mgr(), any(), timeout()) ->
  noproc | timeout | atom().
call_available_worker(QueueManager, Call, Timeout) ->
  Expires =
    case Timeout of
      infinity -> infinity;
      Timeout -> now_in_microseconds() + Timeout * 1000
    end,
  try
    gen_server:call(QueueManager, {available_worker, Call, Expires}, Timeout)
  catch
    _:{noproc, {gen_server, call, _}} ->
      noproc;
    _:{timeout, {gen_server, call, _}} ->
      timeout
  end.

%% @doc Casts a message to the first available worker.
%%      Since we can wait forever for a wpool:cast to be delivered
%%      but we don't want the caller to be blocked, this function
%%      just forwards the cast when it gets the worker
-spec cast_to_available_worker(queue_mgr(), term()) -> ok.
cast_to_available_worker(QueueManager, Cast) ->
  gen_server:cast(QueueManager, {cast_to_available_worker, Cast}).

%% @doc returns the first available worker in the pool
-spec sync_send_event_to_available_worker(queue_mgr(), any(), timeout()) ->
                                          noproc | timeout | atom().
sync_send_event_to_available_worker(QueueManager, Event, Timeout) ->
  Expires =
    case Timeout of
      infinity -> infinity;
      Timeout -> now_in_microseconds() + Timeout * 1000
    end,
  try
    gen_server:call(QueueManager, {sync_event_available_worker,
                                  Event,
                                  Expires}
                                  , Timeout)
  catch
    _:{noproc, {gen_server, call, _}} ->
      noproc;
    _:{timeout, {gen_server, call, _}} ->
      timeout
  end.

%% @doc returns the first available worker in the pool
-spec sync_send_all_event_to_available_worker(queue_mgr(), any(), timeout()) ->
                                              noproc | timeout | atom().
sync_send_all_event_to_available_worker(QueueManager, Event, Timeout) ->
  Expires =
    case Timeout of
      infinity -> infinity;
      Timeout -> now_in_microseconds() + Timeout * 1000
    end,
  try
    gen_server:call(QueueManager, {sync_all_event_available_worker,
                                  Event,
                                  Expires}
                                  , Timeout)
  catch
    _:{noproc, {gen_server, call, _}} ->
      noproc;
    _:{timeout, {gen_server, call, _}} ->
      timeout
  end.

%% @doc Send an event to the first available worker.
%%      Since we can wait forever for a wpool:send_event to be delivered
%%      but we don't want the caller to be blocked, this function
%%      just forwards the event when it gets the worker
-spec send_event_to_available_worker(queue_mgr(), term()) -> ok.
send_event_to_available_worker(QueueManager, Event) ->
  gen_server:cast(QueueManager, {send_event_to_available_worker, Event}).

%% @doc Send an event to the first available worker.
%%      Since we can wait forever for a wpool:send_event to be delivered
%%      but we don't want the caller to be blocked, this function
%%      just forwards the event when it gets the worker
-spec send_all_event_to_available_worker(queue_mgr(), term()) -> ok.
send_all_event_to_available_worker(QueueManager, Event) ->
  gen_server:cast(QueueManager, {send_all_event_to_available_worker, Event}).

%% @doc Mark a brand new worker as available
-spec new_worker(queue_mgr(), atom()) -> ok.
new_worker(QueueManager, Worker) ->
  gen_server:cast(QueueManager, {new_worker, Worker}).

%% @doc Mark a worker as available
-spec worker_ready(queue_mgr(), atom()) -> ok.
worker_ready(QueueManager, Worker) ->
  gen_server:cast(QueueManager, {worker_ready, Worker}).

%% @doc Mark a worker as no longer available
-spec worker_busy(queue_mgr(), atom()) -> ok.
worker_busy(QueueManager, Worker) ->
  gen_server:cast(QueueManager, {worker_busy, Worker}).

%% @doc Decrement the total number of workers
-spec worker_dead(queue_mgr(), atom()) -> ok.
worker_dead(QueueManager, Worker) ->
  gen_server:cast(QueueManager, {worker_dead, Worker}).

%% @doc Return the list of currently existing worker pools.
-type pool_prop()  :: {pool, wpool:name()}.
-type qm_prop()    :: {queue_manager, queue_mgr()}.
-type pool_props() :: [pool_prop() | qm_prop()].      % Not quite strict enough.
-spec pools() -> [pool_props()].
pools() ->
  ets:foldl(
    fun(#wpool{ name=Pool_Name
              , size=Pool_Size
              , qmanager=Queue_Mgr
              , born=Born
              }, Pools) ->
      This_Pool = [
                   {pool,          Pool_Name},
                   {pool_age,      age_in_seconds(Born)},
                   {pool_size,     Pool_Size},
                   {queue_manager, Queue_Mgr}
                  ],
      [This_Pool | Pools]
    end, [], wpool_pool).

%% @doc Returns statistics for this queue.
-spec stats(wpool:name()) ->
  proplists:proplist() | {error, {invalid_pool, wpool:name()}}.
stats(Pool_Name) ->
  case ets:lookup(wpool_pool, Pool_Name) of
    [] -> {error, {invalid_pool, Pool_Name}};
    [#wpool{qmanager=Queue_Manager, size=Pool_Size, born=Born}] ->
        {Available_Workers, Pending_Tasks}
            = gen_server:call(Queue_Manager, worker_counts),
        Busy_Workers = Pool_Size - Available_Workers,
        [
         {pool_age_in_secs,  age_in_seconds(Born)},
         {pool_size,         Pool_Size},
         {pending_tasks,     Pending_Tasks},
         {available_workers, Available_Workers},
         {busy_workers,      Busy_Workers}
        ]
  end.

%% @doc Return a default set of process_info about workers.
-spec proc_info(wpool:name()) -> proplists:proplist().
proc_info(Pool_Name) ->
  Key_Info = [current_location, status,
              stack_size, total_heap_size, memory,
              reductions, message_queue_len],
  proc_info(Pool_Name, Key_Info).

%% @doc Return the currently executing function in the queue manager.
-spec proc_info(wpool:name(), atom() | [atom()]) -> proplists:proplist().
proc_info(Pool_Name, Info_Type) ->
  case ets:lookup(wpool_pool, Pool_Name) of
    [] -> {error, {invalid_pool, Pool_Name}};
    [#wpool{qmanager=Queue_Manager, born=Mgr_Born}] ->
      Age_In_Secs = age_in_seconds(Mgr_Born),
      QM_Pid = whereis(Queue_Manager),
      Mgr_Info =
        [ {age_in_seconds, Age_In_Secs}
        | erlang:process_info(QM_Pid, Info_Type)],
      Workers = wpool_pool:worker_names(Pool_Name),
      Workers_Info =
        [{Worker, worker_info(Worker_Pid, Info_Type)}
         || Worker <- Workers
          , begin
              Worker_Pid = whereis(Worker),
              is_process_alive(Worker_Pid)
            end
        ],
      [{queue_manager, Mgr_Info}, {workers, Workers_Info}]
  end.

worker_info(Worker_Pid, Info_Type) ->
  Secs_Old = wpool_process:age(Worker_Pid) div 1000000,
  {Worker_Pid,
    [{age_in_seconds, Secs_Old} | erlang:process_info(Worker_Pid, Info_Type)]}.

-define(DEFAULT_TRACE_TIMEOUT, 5000).
-define(TRACE_KEY, wpool_trace).

%% @doc Default tracing for 5 seconds to track worker pool execution times
%%      to error.log.
-spec trace(wpool:name()) -> ok.
trace(Pool_Name) ->
  trace(Pool_Name, true, ?DEFAULT_TRACE_TIMEOUT).

%% @doc Turn pool tracing on and off.
-spec trace(wpool:name(), boolean(), pos_integer()) ->
  ok | {error, {invalid_pool, wpool:name()}}.
trace(Pool_Name, true, Timeout) ->
  case ets:lookup(wpool_pool, Pool_Name) of
    [] -> {error, {invalid_pool, Pool_Name}};
    [#wpool{}] ->
      error_logger:info_msg(
        "[~p] Tracing turned on for worker_pool ~p",
        [?TRACE_KEY, Pool_Name]),
      {Tracer_Pid, _Ref} = trace_timer(Pool_Name),
      trace(Pool_Name, true, Tracer_Pid, Timeout)
  end;
trace(Pool_Name, false, _Timeout) ->
  case ets:lookup(wpool_pool, Pool_Name) of
    [] -> {error, {invalid_pool, Pool_Name}};
    [#wpool{}] ->
      trace(Pool_Name, false, no_pid, 0)
  end.

-spec trace(wpool:name(), boolean(), pid() | no_pid, non_neg_integer()) -> ok.
trace(Pool_Name, Trace_On, Tracer_Pid, Timeout) ->
  Workers = wpool_pool:worker_names(Pool_Name),
  Trace_Options = [timestamp, 'receive', send],
  [case Trace_On of
    true  ->
      erlang:trace(Worker_Pid, true,  [{tracer, Tracer_Pid} | Trace_Options]);
    false ->
      erlang:trace(Worker_Pid, false, Trace_Options)
   end || Worker <- Workers, is_process_alive(Worker_Pid = whereis(Worker))],
  trace_off(Pool_Name, Trace_On, Tracer_Pid, Timeout).

trace_off(Pool_Name, false, _Tracer_Pid, _Timeout) ->
  error_logger:info_msg(
    "[~p] Tracing turned off for worker_pool ~p", [?TRACE_KEY, Pool_Name]),
  ok;
trace_off(Pool_Name, true,   Tracer_Pid,  Timeout) ->
  _ = timer:apply_after(Timeout, ?MODULE, trace, [Pool_Name, false, Timeout]),
  _ = erlang:send_after(Timeout, Tracer_Pid, quit),
  error_logger:info_msg(
    "[~p] Tracer pid ~p scheduled to end in ~p msec for worker_pool ~p",
    [?TRACE_KEY, Tracer_Pid, Timeout, Pool_Name]),
  ok.

%% @doc Collect trace timing results to report succinct run times.
-spec trace_timer(wpool:name()) -> {pid(), reference()}.
trace_timer(Pool_Name) ->
  {Pid, Reference} =
    spawn_monitor(fun() -> report_trace_times(Pool_Name) end),
  register(wpool_trace_timer, Pid),
  error_logger:info_msg(
    "[~p] Tracer pid ~p started for worker_pool ~p",
    [?TRACE_KEY, Pid, Pool_Name]),
  {Pid, Reference}.

-spec report_trace_times(wpool:name()) -> ok.
report_trace_times(Pool_Name) ->
  receive
    quit -> summarize_pending_times(Pool_Name);
    {trace_ts, Worker, 'receive', {'$gen_call', From, Request}, Time_Started} ->
      Props = {start, Time_Started, request, Request, worker, Worker},
      undefined = put({?TRACE_KEY, From}, Props),
      report_trace_times(Pool_Name);
    {trace_ts, Worker, send, {Ref, Result}, From_Pid, Time_Finished} ->
      case erase({?TRACE_KEY, {From_Pid, Ref}}) of
        undefined -> ok;
        {start, Time_Started, request, Request, worker, Worker} ->
          Elapsed = timer:now_diff(Time_Finished, Time_Started),
          error_logger:info_msg("[~p] ~p usec: ~p  request: ~p  reply: ~p",
                                [?TRACE_KEY, Worker, Elapsed, Request, Result])
      end,
      report_trace_times(Pool_Name);
    _Sys_Or_Other_Msg ->
      report_trace_times(Pool_Name)
  end.

summarize_pending_times(Pool_Name) ->
  Now = os:timestamp(),
  Fmt_Msg = "[~p] Unfinished task ~p usec: ~p  request: ~p",
  [error_logger:info_msg(Fmt_Msg, [?TRACE_KEY, Worker, Elapsed, Request])
   || { {?TRACE_KEY, _From}
      , {start, Time_Started, request, Request, worker, Worker}} <- get(),
      (Elapsed = timer:now_diff(Now, Time_Started)) > -1],
  error_logger:info_msg(
    "[~p] Tracer pid ~p ended for worker_pool ~p",
    [?TRACE_KEY, self(), Pool_Name]),
  ok.


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%% @private
-spec init(wpool:name()) -> {ok, state()}.
init(WPool) ->
  put(pending_tasks, 0),
  {ok, #state{wpool=WPool, clients=queue:new(), workers=gb_sets:new()}}.

-type worker_event() :: new_worker | worker_dead | worker_busy | worker_ready.
%% @private
-spec handle_cast({worker_event(), atom()}, state()) -> {noreply, state()}.
handle_cast({new_worker, Worker}, State) ->
  handle_cast({worker_ready, Worker}, State);
handle_cast({worker_dead, Worker}, #state{workers=Workers} = State) ->
  New_Workers = gb_sets:delete_any(Worker, Workers),
  {noreply, State#state{workers=New_Workers}};
handle_cast({worker_busy, Worker}, #state{workers=Workers} = State) ->
  {noreply, State#state{workers = gb_sets:delete_any(Worker, Workers)}};
handle_cast({worker_ready, Worker},
            #state{workers=Workers, clients=Clients} = State) ->
  case queue:out(Clients) of
    {empty, _Clients} ->
      {noreply, State#state{workers = gb_sets:add(Worker, Workers)}};
    {{value, {cast, Cast}}, New_Clients} ->
       dec_pending_tasks(),
       ok = wpool_process:cast(Worker, Cast),
       {noreply, State#state{clients = New_Clients}};
    {{value, {Client = {ClientPid, _}, Call, Expires}}, New_Clients} ->
      dec_pending_tasks(),
      New_State = State#state{clients = New_Clients},
      case is_process_alive(ClientPid) andalso
           Expires > now_in_microseconds() of
        true ->
          ok = wpool_process:cast_call(Worker, Client, Call),
          {noreply, New_State};
        false ->
          handle_cast({worker_ready, Worker}, New_State)
      end;
      {{value, {send_event, Event}}, New_Clients} ->
        dec_pending_tasks(),
        ok = wpool_fsm_process:send_event(Worker, Event),
        {noreply, State#state{clients = New_Clients}}
  end;
handle_cast({cast_to_available_worker, Cast},
            #state{workers=Workers, clients=Clients} = State) ->
  case gb_sets:is_empty(Workers) of
    true ->
      inc_pending_tasks(),
      {noreply, State#state{clients = queue:in({cast, Cast}, Clients)}};
    false ->
      {Worker, New_Workers} = gb_sets:take_smallest(Workers),
      ok = wpool_process:cast(Worker, Cast),
      {noreply, State#state{workers = New_Workers}}
  end;
handle_cast({send_event_to_available_worker, Event},
            #state{workers=Workers, clients=Clients} = State) ->
  case gb_sets:is_empty(Workers) of
  true ->
    inc_pending_tasks(),
    {noreply, State#state{clients = queue:in({send_event, Event}, Clients)}};
  false ->
    {Worker, New_Workers} = gb_sets:take_smallest(Workers),
    ok = wpool_fsm_process:send_event(Worker, Event),
    {noreply, State#state{workers = New_Workers}}
  end;
handle_cast({send_all_event_to_available_worker, Event},
            #state{workers=Workers, clients=Clients} = State) ->
    case gb_sets:is_empty(Workers) of
    true ->
    inc_pending_tasks(),
    {noreply, State#state{clients = queue:in({send_event, Event}, Clients)}};
    false ->
    {Worker, New_Workers} = gb_sets:take_smallest(Workers),
    ok = wpool_fsm_process:send_all_state_event(Worker, Event),
    {noreply, State#state{workers = New_Workers}}
  end.

-type from() :: {pid(), reference()}.
-type call_request() ::
  {available_worker, infinity|pos_integer()} | worker_counts.
%% @private
-spec handle_call(call_request(), from(), state())
                 -> {reply, {ok, atom()}, state()} | {noreply, state()}.

handle_call({available_worker, Call, Expires}, Client = {ClientPid, _Ref},
            #state{workers=Workers, clients=Clients} = State) ->
  case gb_sets:is_empty(Workers) of
    true ->
      inc_pending_tasks(),
      { noreply
      , State#state{clients = queue:in({Client, Call, Expires}, Clients)}
      };
    false ->
      {Worker, New_Workers} = gb_sets:take_smallest(Workers),
      %NOTE: It could've been a while since this call was made, so we check
      case erlang:is_process_alive(ClientPid) andalso
           Expires > now_in_microseconds() of
        true  ->
          ok = wpool_process:cast_call(Worker, Client, Call),
          {noreply, State#state{workers = New_Workers}};
        false ->
          {noreply, State}
      end
  end;
handle_call({sync_event_available_worker, Event, Expires},
            Client = {ClientPid, _Ref},
            #state{workers=Workers, clients=Clients} = State) ->
  case gb_sets:is_empty(Workers) of
    true ->
      inc_pending_tasks(),
      { noreply
        , State#state{clients = queue:in({Client, Event, Expires}, Clients)}
      };
    false ->
      {Worker, New_Workers} = gb_sets:take_smallest(Workers),
      %NOTE: It could've been a while since this call was made, so we check
      case erlang:is_process_alive(ClientPid) andalso
        Expires > now_in_microseconds() of
        true  ->
          Reply = wpool_fsm_process:sync_send_event(Worker, Event),
          gen_server:reply(Client, Reply),
          {noreply, State#state{workers = New_Workers}};
        false ->
          {noreply, State}
      end
  end;
handle_call({sync_all_event_available_worker, Event, Expires},
            Client = {ClientPid, _Ref},
            #state{workers=Workers, clients=Clients} = State) ->
  case gb_sets:is_empty(Workers) of
    true ->
    inc_pending_tasks(),
    { noreply
    , State#state{clients = queue:in({Client, Event, Expires}, Clients)}
    };
    false ->
    {Worker, New_Workers} = gb_sets:take_smallest(Workers),
    %NOTE: It could've been a while since this call was made, so we check
    case erlang:is_process_alive(ClientPid) andalso
      Expires > now_in_microseconds() of
      true  ->
        Reply = wpool_fsm_process:sync_send_all_state_event(Worker, Event),
        gen_server:reply(Client, Reply),
        {noreply, State#state{workers = New_Workers}};
      false ->
        {noreply, State}
    end
  end;
handle_call(worker_counts, _From,
            #state{workers=Available_Workers} = State) ->
  Available = gb_sets:size(Available_Workers),
  {reply, {Available, get(pending_tasks)}, State}.

%% @private
-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info(_Info, State) -> {noreply, State}.

%% @private
-spec terminate(atom(), state()) -> ok.
terminate(Reason, #state{clients=Clients} = _State) ->
  return_error(Reason, queue:out(Clients)).

%% @private
-spec code_change(string(), state(), any()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% private
%%%===================================================================
inc_pending_tasks() -> inc(pending_tasks).
dec_pending_tasks() -> dec(pending_tasks).

inc(Key) -> put(Key, get(Key) + 1).
dec(Key) -> put(Key, get(Key) - 1).

return_error(_Reason, {empty, _Q}) -> ok;
return_error(Reason, {{value, {cast, Cast}}, Q}) ->
  error_logger:error_msg("Cast lost on terminate ~p: ~p", [Reason, Cast]),
  return_error(Reason, queue:out(Q));
return_error(Reason, {{value, {From, _Expires}}, Q}) ->
  _  = gen_server:reply(From, {error, {queue_shutdown, Reason}}),
  return_error(Reason, queue:out(Q)).

now_in_microseconds() -> timer:now_diff(os:timestamp(), {0, 0, 0}).

age_in_seconds(Born) -> timer:now_diff(os:timestamp(), Born) div 1000000.
