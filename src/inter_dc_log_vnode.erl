%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either expressed or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% Description and complete License: see LICENSE file.
%% -------------------------------------------------------------------

-module(inter_dc_log_vnode).
-author("Kevin Bartik <k_bartik12@cs.uni-kl.de>").
-include("inter_dc.hrl").
-behaviour(riak_core_vnode).

-export([start_vnode/1,
    init/1,
    handle_command/3,
    handoff_starting/2,
    handoff_cancelled/1,
    handoff_finished/2,
    handle_handoff_command/3,
    handle_handoff_data/2,
    encode_handoff_item/2,
    is_empty/1,
    terminate/2,
    delete/1,
    handle_info/2,
    handle_exit/3,
    handle_coverage/4,
    handle_overload_command/3,
    handle_overload_info/2]).

-record(state, {
    partition :: partition(),
    txid_to_journal_entry_list_map = #{} :: #{txid() => [journal_entry()]},
    last_sent_txn_timestamp = 0 :: timestamp(),
    last_sent_txn_tracking_num = gingko_utils:get_default_txn_tracking_num() :: txn_tracking_num(),
    ping_active = true :: boolean(),
    ping_timer = none :: none | reference()
}).
-type state() :: #state{}.

%%%===================================================================
%%% Public API
%%%===================================================================

%%%===================================================================
%%% Spawning and vnode implementation
%%%===================================================================

-spec start_vnode(integer()) -> any().
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
    default_vnode_behaviour:init(?MODULE, [Partition]),
    {ok, restart_ping_timer(#state{partition = Partition})}.

handle_command(Request = hello, Sender, State) ->
    default_vnode_behaviour:handle_command(?MODULE, Request, Sender, State),
    {reply, ok, State};

handle_command(Request = {journal_entry, JournalEntry = #journal_entry{tx_id = TxId}}, Sender, State = #state{txid_to_journal_entry_list_map = TxIdToJournalEntryListMap}) ->
    default_vnode_behaviour:handle_command(?MODULE, Request, Sender, State),
    NewTxIdToJournalEntryListMap = general_utils:maps_append(TxId, JournalEntry, TxIdToJournalEntryListMap),
    NewState = broadcast_if_commit(JournalEntry, State#state{txid_to_journal_entry_list_map = NewTxIdToJournalEntryListMap}),
    {reply, ok, NewState};

handle_command(Request = {request_remote_txns, TargetDCID, TxnNumList}, Sender, State) ->
    default_vnode_behaviour:handle_command(?MODULE, Request, Sender, State),
    ok = request_remote_txns(TargetDCID, TxnNumList, State),
    {reply, ok, State};

handle_command(Request = {set_ping_active, Active}, Sender, State) ->
    default_vnode_behaviour:handle_command(?MODULE, Request, Sender, State),
    {reply, ok, State#state{ping_active = Active}};

handle_command(Request = ping_event, Sender, State) ->
    default_vnode_behaviour:handle_command(?MODULE, Request, Sender, State),
    {reply, ok, restart_ping_timer(ping(State))};

handle_command(Request, Sender, State) -> default_vnode_behaviour:handle_command_crash(?MODULE, Request, Sender, State).
handoff_starting(TargetNode, State) -> default_vnode_behaviour:handoff_starting(?MODULE, TargetNode, State).
handoff_cancelled(State) -> default_vnode_behaviour:handoff_cancelled(?MODULE, State).
handoff_finished(TargetNode, State) -> default_vnode_behaviour:handoff_finished(?MODULE, TargetNode, State).
handle_handoff_command(Request, Sender, State) ->
    default_vnode_behaviour:handle_handoff_command(?MODULE, Request, Sender, State).
handle_handoff_data(BinaryData, State) -> default_vnode_behaviour:handle_handoff_data(?MODULE, BinaryData, State).
encode_handoff_item(Key, Value) -> default_vnode_behaviour:encode_handoff_item(?MODULE, Key, Value).
is_empty(State) -> default_vnode_behaviour:is_empty(?MODULE, State).
terminate(Reason, State) -> default_vnode_behaviour:terminate(?MODULE, Reason, State).
delete(State) -> default_vnode_behaviour:delete(?MODULE, State).
-spec handle_info(term(), state()) -> no_return().
handle_info(Request, State) -> default_vnode_behaviour:handle_info_crash(?MODULE, Request, State).
handle_exit(Pid, Reason, State) -> default_vnode_behaviour:handle_exit(?MODULE, Pid, Reason, State).
handle_coverage(Request, KeySpaces, Sender, State) ->
    default_vnode_behaviour:handle_coverage(?MODULE, Request, KeySpaces, Sender, State).
handle_overload_command(Request, Sender, Partition) ->
    default_vnode_behaviour:handle_overload_command(?MODULE, Request, Sender, Partition).
handle_overload_info(Request, Partition) -> default_vnode_behaviour:handle_overload_info(?MODULE, Request, Partition).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec restart_ping_timer(state()) -> state().
restart_ping_timer(State = #state{ping_timer = CurrentPingTimer}) ->
    PingIntervalMillis = gingko_env_utils:get_inter_dc_txn_ping_interval_millis(),
    NewPingTimer = gingko_dc_utils:update_timer(CurrentPingTimer, true, PingIntervalMillis, ping_event, true),
    State#state{ping_timer = NewPingTimer}.

-spec ping(state()) -> state().
ping(State = #state{ping_active = false}) -> State;
ping(State = #state{partition = Partition, last_sent_txn_timestamp = Timestamp, last_sent_txn_tracking_num = LastSentTxnTrackingNum}) ->
    CurrentTime = gingko_dc_utils:get_timestamp(),
    PingInterval = gingko_env_utils:get_inter_dc_txn_ping_interval_millis(),
    %%We send pings only to partitions that we have not sent transactions to in a while
    case (CurrentTime - Timestamp) >= 1000 * PingInterval of
        true ->
            inter_dc_txn_sender:broadcast_ping(Partition, LastSentTxnTrackingNum),
            State#state{last_sent_txn_timestamp = CurrentTime};
        false -> State
    end.

-spec broadcast_if_commit(journal_entry(), state()) -> state().
broadcast_if_commit(#journal_entry{tx_id = TxId, args = #commit_txn_args{txn_tracking_num = TxnTrackingNum}}, State = #state{partition = Partition, txid_to_journal_entry_list_map = TxIdToJournalEntryListMap}) ->
    TxJournalEntryList = maps:get(TxId, TxIdToJournalEntryListMap),
    NewTxIdToJournalEntryListMap = maps:remove(TxId, TxIdToJournalEntryListMap),
    LastSentTxnTimestamp = gingko_dc_utils:get_timestamp(),
    inter_dc_txn_sender:broadcast_txn(Partition, TxnTrackingNum, TxJournalEntryList),
    State#state{txid_to_journal_entry_list_map = NewTxIdToJournalEntryListMap, last_sent_txn_timestamp = LastSentTxnTimestamp, last_sent_txn_tracking_num = TxnTrackingNum};
broadcast_if_commit(_, State) -> State.

-spec request_remote_txns(dcid(), [txid()], state()) -> ok.
request_remote_txns(_, [], _) -> ok;
request_remote_txns(TargetDCID, TxnNumList, #state{partition = TargetPartition}) ->
    inter_dc_request_sender:perform_journal_read_request({TargetDCID, TargetPartition}, TxnNumList,
        fun(InterDcTxnList, _) ->
            %%Assume correctness here
            SortedInterDcTxnList =
                lists:sort(
                    fun(#inter_dc_txn{last_sent_txn_tracking_num = {TxnNum1, _, _}}, #inter_dc_txn{last_sent_txn_tracking_num = {TxnNum2, _, _}}) ->
                        TxnNum1 =< TxnNum2
                    end, InterDcTxnList),
            lists:foreach(
                fun(InterDcTxn) ->
                    gingko_dc_utils:call_gingko_async(TargetPartition, ?GINGKO_LOG, {add_remote_txn, InterDcTxn})
                end, SortedInterDcTxnList)
        end).
