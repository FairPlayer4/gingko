%% -------------------------------------------------------------------
%%
%% Copyright <2013-2018> <
%%  Technische Universität Kaiserslautern, Germany
%%  Université Pierre et Marie Curie / Sorbonne-Université, France
%%  Universidade NOVA de Lisboa, Portugal
%%  Université catholique de Louvain (UCL), Belgique
%%  INESC TEC, Portugal
%% >
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
%% List of the contributors to the development of Antidote: see AUTHORS file.
%% Description and complete License: see LICENSE file.
%% -------------------------------------------------------------------

-module(bcountermgr_SUITE).
-include("gingko.hrl").

%% common_test callbacks
-export([init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    all/0]).

%% tests
-export([new_bcounter_test/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(TYPE, antidote_crdt_counter_b).
-define(RETRY_COUNT, 10).

init_per_suite(Config) ->
    test_utils:init_single_dc(?MODULE, Config).

end_per_suite(Config) ->
    Config.

init_per_testcase(Name, Config) ->
    ct:pal("[ STARTING ] ~p", [Name]),
    Config.

end_per_testcase(Name, _) ->
    ct:pal("[ OK ] ~p", [Name]),
    ok.

all() ->
    [
        new_bcounter_test
    ].

%% Test creating a new `bcounter()'.
new_bcounter_test(Config) ->
    Bucket = ?BUCKET,
    Node = proplists:get_value(node, Config),
    Key = bcounter1_mgr,

    % FIXME why is this not working?
    %{Value, _}  = antidote_test_utils:read_b_counter(Node, Key, Bucket),
    %?assertEqual(0, Value).
    check_read(Node, Key, 0, Bucket).

read_si(Node, Key, CommitTime, Bucket) ->
    ct:pal("Read si ~p", [Key]),
    rpc:call(Node, antidote, read_objects, [CommitTime, [], [{Key, ?TYPE, Bucket}]]).


check_read(Node, Key, Expected, CommitTime, Bucket) ->
    {ok, [Obj], _CT} = read_si(Node, Key, CommitTime, Bucket),
    ?assertEqual(Expected, ?TYPE:permissions(Obj)).

check_read(Node, Key, Expected, Bucket) ->
    check_read(Node, Key, Expected, ignore, Bucket).
