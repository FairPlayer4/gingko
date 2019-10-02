%% @doc The operation log which receives requests and manages recovery of log files.
%% @hidden
-module(gingko_op_log_server).
-include("gingko.hrl").

-behaviour(gen_server).

%% TODO
-type server() :: any().
-type log() :: any().
-type log_entry() :: any().
-type gen_from() :: any().

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2,  handle_info/2]).

%% ==============
%% API
%% Internal api documentation and types for the gingko op log gen_server
%% ==============

%%%===================================================================
%%% State
%%%===================================================================


% log starts with this default index
-define(STARTING_INDEX, 0).


%% @doc Starts the op log server for given server name and recovery receiver process
-spec start_link(term(), pid()) -> {ok, pid()}.
start_link({JournalLogName, CheckpointLogName}, RecoveryReceiver) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, {{JournalLogName, CheckpointLogName}, RecoveryReceiver}, []).


%% @doc Initializes the internal server state
-spec init({{string(), string()}, pid()}) -> {ok, #log_server_state{}}.
init({{JournalLogName, CheckpointLogName}, RecoveryReceiver}) ->
  logger:notice(#{
    action => "Starting op log server",
    registered_as => ?MODULE,
    name => JournalLogName,
    receiver => RecoveryReceiver
  }),

  case RecoveryReceiver of
    none -> ActualReceiver =
      spawn(fun Loop() ->
        receive Message -> logger:notice("Received dummy message: ~p",[Message]) end,
        Loop()
      end);
    _ -> ActualReceiver = RecoveryReceiver
  end,


  {ok, LogServer} = gingko_sync_server:start_link({JournalLogName, CheckpointLogName}),

  gen_server:cast(self(), start_recovery),
  {ok, create_initial_state(ActualReceiver, JournalLogName, CheckpointLogName, LogServer)}.


%% ------------------
%% ASYNC LOG RECOVERY
%% ------------------

%% @doc Either
%% 1) starts async recovery and does not reply until recovery is finished
%% or
%% 2) finishes async recovery and replies to waiting processes
-spec handle_cast
    (start_recovery, #log_server_state{}) -> {noreply, #log_server_state{}};          %1)
    ({finish_recovery, #{}}, #log_server_state{}) -> {noreply, #log_server_state{}}.  %2)
handle_cast(start_recovery, State) when State#log_server_state.recovering == true ->
  JournalLogName = State#log_server_state.journal_log_name,
  CheckpointLogName = State#log_server_state.checkpoint_log_name,
  Receiver = State#log_server_state.recovery_receiver,
  LogServer = State#log_server_state.sync_server,
  logger:info("[~p] Async recovery started", [JournalLogName]),

  GenServer = self(),
  AsyncRecovery = fun() ->
    NextIndex = recover_all_logs(JournalLogName, Receiver, LogServer),
    %% TODO recovery
    NextIndex = 0,
    gen_server:cast(GenServer, {finish_recovery, NextIndex})
                  end,
  spawn_link(AsyncRecovery),
  {noreply, State};

handle_cast({finish_recovery, NextIndexMap}, State) ->
  % TODO
  % reply to waiting processes to try their requests again
  reply_retry_to_waiting(State#log_server_state.waiting_for_reply),

  % save write-able index map and finish recovery
  logger:info("[~p] Recovery process finished", [State#log_server_state.journal_log_name]),
  {noreply, State#log_server_state{recovering = false, next_index = NextIndexMap, waiting_for_reply = []}};

handle_cast(Msg, State) ->
  logger:warning("[~p] Swallowing unexpected message: ~p", [State#log_server_state.journal_log_name, Msg]),
  {noreply, State}.


terminate(_Reason, State) ->
  gen_server:stop(State#log_server_state.sync_server),
  ok.


%% @doc Either
%% 1) adds a log entry for given node and a {Index, Data} pair
%% or
%% 2) reads the log
-spec handle_call
    ({add_log_entry, log_entry()}, gen_from(), #log_server_state{}) ->
  {noreply, #log_server_state{}} | %% if still recovering
  {reply, {error, index_already_written}, #log_server_state{}} | %% if index is already written
  {reply, ok, #log_server_state{}}; %% entry is persisted
    ({read_log_entries, any(), integer(), integer(), fun((log_entry(), Acc) -> Acc), Acc}, gen_from(), #log_server_state{}) ->
  {noreply, #log_server_state{}} | %% if still recovering or index for given node behind
  {reply, {ok, Acc}, #log_server_state{}}. %% accumulated entries

handle_call({add_log_entry, _Data}, From, State) when State#log_server_state.recovering == true ->
  logger:notice("[~p] Waiting for recovery: ~p", [State#log_server_state.journal_log_name, From]),
  Waiting = State#log_server_state.waiting_for_reply,
  {noreply, State#log_server_state{ waiting_for_reply = Waiting ++ [From] }};

handle_call({add_log_entry, Data}, From, State) ->
  logger:notice(#{
    action => "Append to log",
    name => State#log_server_state.journal_log_name,
    data => Data,
    from => From
  }),


  NextIndex = State#log_server_state.next_index,
  LogName = State#log_server_state.journal_log_name,
  LogServer = State#log_server_state.sync_server,
  Waiting = State#log_server_state.waiting_for_reply,

  {ok, Log} = gen_server:call(LogServer, {get_log, LogName}),
  logger:notice(#{
    action => "Logging",
    log => Log,
    index => NextIndex,
    data => Data
  }),

  ok = disk_log:log(Log, {NextIndex, Data}),

  % wait for sync reply
  gen_server:cast(LogServer, {sync_log, LogName, self()}),
  receive log_persisted -> ok end,

  logger:info("[~p] Log entry at ~p persisted",
    [State#log_server_state.journal_log_name, NextIndex]),

  % index of another request may be up to date, send retry messages
  reply_retry_to_waiting(Waiting),
  {reply, ok, State#log_server_state{
    % increase index counter for node by one
    next_index = NextIndex + 1,
    % empty waiting queue
    waiting_for_reply = []
  }};


handle_call(_Request, From, State)
  when State#log_server_state.recovering == true ->
  logger:info("[~p] Read, waiting for recovery", [State#log_server_state.journal_log_name]),
  Waiting = State#log_server_state.waiting_for_reply,
  {noreply, State#log_server_state{ waiting_for_reply = Waiting ++ [From] }};

handle_call({read_log_entries, FirstIndex, LastIndex, F, Acc}, _From, State) ->
  LogName = State#log_server_state.journal_log_name,
  LogServer = State#log_server_state.sync_server,
  Waiting = State#log_server_state.waiting_for_reply,
  %% simple implementation, read ALL terms, then filter
  %% can be improved performance wise, stop at last index

  {ok, Log} = gen_server:call(LogServer, {get_log, LogName}),
  %% TODO this will most likely cause a timeout to the gen_server caller, what to do?
  Terms = read_journal_log(Log),

  % filter index
  FilterByIndex = fun({Index, _}) -> Index >= FirstIndex andalso ((LastIndex == all) or (Index =< LastIndex)) end,
  FilteredTerms = lists:filter(FilterByIndex, Terms),

  % apply given aggregator function
  ReplyAcc = lists:foldl(F, Acc, FilteredTerms),

  reply_retry_to_waiting(Waiting),
  {reply, {ok, ReplyAcc}, State#log_server_state{waiting_for_reply = []}}.


handle_info(Msg, State) ->
  logger:warning("Swallowing unexpected message: ~p", [Msg]),
  {noreply, State}.




%%%===================================================================
%%% Private Functions Implementation
%%%===================================================================

%% @doc Replies a 'retry' message to all waiting process to retry their action again
-spec reply_retry_to_waiting([gen_from()]) -> ok.
reply_retry_to_waiting(WaitingProcesses) ->
  Reply = fun(Process, _) -> gen_server:reply(Process, retry) end,
  lists:foldl(Reply, void, WaitingProcesses),
  ok.


%% @doc recovers all logs for given server name
%%      the server name should be the local one
%%      also ensures that the directory actually exists
%%
%% sends pid() ! {log_recovery, Node, {Index, Data}}
%%      for each entry in one log
%%
%% sends pid() ! {log_recovery_done}
%%      once after processing finished
-spec recover_all_logs(server(), pid(), pid()) -> any().
%%noinspection ErlangUnboundVariable
recover_all_logs(LogName, Receiver, LogServer) when is_atom(LogName) ->
  recover_all_logs(LogName, Receiver, LogServer);
recover_all_logs(LogName, Receiver, LogServer) ->
  % make sure the folder exists
  LogPath = gingko_sync_server:log_dir_base(LogName),
  filelib:ensure_dir(LogPath),

  ProcessLogFile = fun(LogFile, Index) ->
    logger:notice(#{
      action => "Recovering logfile",
      log => LogName,
      file => LogFile
    }),

    {ok, Log} = gen_server:call(LogServer, {get_log, LogName}),

    % read all terms
    Terms = read_journal_log(Log),

    logger:notice(#{
      terms => Terms
    }),

    % For each entry {log_recovery, {Index, Data}} is sent
    SendTerm = fun({LogIndex, Data}, _) -> Receiver ! {log_recovery, {LogIndex, Data}} end,
    lists:foldl(SendTerm, void, Terms),

    case Terms of
      [] -> LastIndex = 0;
      _ -> {LastIndex, _} = hd(lists:reverse(Terms))
    end,

    case Index =< LastIndex of
      true -> logger:info("Jumping from ~p to ~p index", [Index, LastIndex]);
      _ -> logger:emergency("Index corrupt! ~p to ~p jump found", [Index, LastIndex])
    end,

    LastIndex
                   end,

  {ok, LogFiles} = file:list_dir(LogPath),

  % accumulate node -> next free index
  IndexAcc = 0,

  LastIndex = lists:foldl(ProcessLogFile, IndexAcc, LogFiles),

  logger:notice("Receiver: ~p", [Receiver]),
  Receiver ! log_recovery_done,

  LastIndex.


%% @doc reads all terms from given log
-spec read_journal_log(log()) -> [term()].
read_journal_log(Log) ->
  read_journal_log(Log, [], start).


read_journal_log(Log, Terms, Cont) ->
  case disk_log:chunk(Log, Cont) of
    eof -> Terms;
    {Cont2, ReadTerms} -> read_journal_log(Log, Terms ++ ReadTerms, Cont2)
  end.

%% @doc reads all terms from given log
-spec read_checkpoint_log(log()) -> dict().
read_checkpoint_log(Log) ->
  case disk_log:chunk(Log, start) of
    eof -> dict:new();
    {_Cont, ReadTerms} -> ReadTerms
  end.

create_initial_state(ActualReceiver, JournalLogName, CheckpointLogName, LogServer) ->
  #log_server_state{
    recovery_receiver = ActualReceiver,
    recovering = true,
    journal_log_name = JournalLogName,
    checkpoint_log_name = CheckpointLogName,
    log_data_structure = not_open,

    sync_server = LogServer,
    next_index = ?STARTING_INDEX
  }.

create_updated_state(State, JournalLog, CheckpointLog) ->
  NewLogDataStructure = #log_data_structure{
                            persistent_journal_log = JournalLog,
                            journal_entry_list = read_journal_log(JournalLog),
                            persistent_checkpoint_log = CheckpointLog,
                            checkpoint_key_value_map = read_checkpoint_log(CheckpointLog) },
  State#log_server_state{
    log_data_structure = NewLogDataStructure
  }.



















%%%===================================================================
%%% Unit Tests
%%%===================================================================

%%-ifdef(TEST).
%%-include_lib("eunit/include/eunit.hrl").
%%
%%main_test_() ->
%%  {foreach,
%%    fun setup/0,
%%    fun cleanup/1,
%%    [
%%      fun read_test/1
%%    ]}.
%%
%%% Setup and Cleanup
%%setup() ->
%%  os:putenv("RESET_LOG_FILE", "true"),
%%  ok.
%%
%%cleanup(Pid) ->
%%  gen_server:stop(Pid).
%%
%%
%%read_test(_) ->
%%  fun() ->
%%    {ok, Pid} = gingko_op_log_server:start_link(?LOGGING_MASTER, none),
%%
%%    Entry = #log_operation{
%%      tx_id = 0,
%%      op_type = commit,
%%      log_payload = #update_log_payload{key = a, type = mv_reg , op = {1,1}}},
%%
%%    % write one entry
%%    ok = gingko_op_log:append(Pid, {data}),
%%    ok = gingko_op_log:append(Pid, {Entry}),
%%
%%    % read entry
%%    {ok, [{0, {data}}, {1, {Entry}}]} = gingko_op_log:read_log_entries(Pid, 0, all)
%%  end.
%%
%%%%multi_read_test(Log) ->
%%%%  fun() ->
%%%%    Node = e_multi,
%%%%    start(Node),
%%%%
%%%%    ok = minidote_op_log:add_log_entry(Log, Node, {?STARTING_INDEX, {data_1}}),
%%%%    ok = minidote_op_log:add_log_entry(Log, Node, {?STARTING_INDEX + 1, {data_2}}),
%%%%    ok = minidote_op_log:add_log_entry(Log, Node, {?STARTING_INDEX + 2, {data_3}}),
%%%%
%%%%    % read entry
%%%%    {ok, [{?STARTING_INDEX, {data_1}}]} = minidote_op_log:read_log_entries(Log, Node, ?STARTING_INDEX, ?STARTING_INDEX),
%%%%    {ok, [{?STARTING_INDEX + 1, {data_2}}]} = minidote_op_log:read_log_entries(Log, Node, ?STARTING_INDEX + 1, ?STARTING_INDEX + 1),
%%%%    {ok, [{?STARTING_INDEX + 2, {data_3}}]} = minidote_op_log:read_log_entries(Log, Node, ?STARTING_INDEX + 2, ?STARTING_INDEX + 2),
%%%%
%%%%    {ok, [{?STARTING_INDEX + 1, {data_2}}, {?STARTING_INDEX + 2, {data_3}}]} = minidote_op_log:read_log_entries(Log, Node, ?STARTING_INDEX + 1, ?STARTING_INDEX + 2),
%%%%    %% OOB
%%%%    {ok, [{?STARTING_INDEX + 1, {data_2}}, {?STARTING_INDEX + 2, {data_3}}]} = minidote_op_log:read_log_entries(Log, Node, ?STARTING_INDEX + 1, ?STARTING_INDEX + 3),
%%%%    %% all
%%%%    {ok, [{?STARTING_INDEX + 1, {data_2}}, {?STARTING_INDEX + 2, {data_3}}]} = minidote_op_log:read_log_entries(Log, Node, ?STARTING_INDEX + 1, all),
%%%%    fin(Node)
%%%%  end.
%%%%
%%%%empty_read_test(Log) ->
%%%%  fun() ->
%%%%    Node = e_empty,
%%%%    start(Node),
%%%%
%%%%    {ok, []} = minidote_op_log:read_log_entries(Log, Node, ?STARTING_INDEX, all),
%%%%
%%%%    fin(Node)
%%%%  end.
%%
%%-endif.
