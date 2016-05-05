%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Helium Systems, Inc.  All Rights Reserved.
%% Copyright (c) 2016 Christopher Meiklejohn.  All Rights Reserved.
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
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(partisan_peer_service_manager).

-behaviour(gen_server).

%% API
-export([start_link/0,
         members/0,
         get_local_state/0,
         get_actor/0,
         join/1,
         leave/0,
         update_state/1,
         delete_state/0,
         send_message/2,
         forward_message/3,
         receive_message/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("partisan.hrl").

-type actor() :: binary().
-type pending() :: [node_spec()].
-type membership() :: ?SET:orswot().
-type connections() :: dict:dict(node(), port()).

-record(state, {actor :: actor(),
                pending :: pending(),
                membership :: membership(),
                connections :: connections() }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Return membership list.
members() ->
    gen_server:call(?MODULE, members, infinity).

%% @doc Return local node's view of cluster membership.
get_local_state() ->
    gen_server:call(?MODULE, get_local_state, infinity).

%% @doc Return local node's current actor.
get_actor() ->
    gen_server:call(?MODULE, get_actor, infinity).

%% @doc Update cluster state.
update_state(State) ->
    gen_server:call(?MODULE, {update_state, State}, infinity).

%% @doc Delete state.
delete_state() ->
    gen_server:call(?MODULE, delete_state, infinity).

%% @doc Send message to a remote manager.
send_message(Name, Message) ->
    gen_server:call(?MODULE, {send_message, Name, Message}, infinity).

%% @doc Forward message to registered process on the remote side.
forward_message(Name, ServerRef, Message) ->
    gen_server:call(?MODULE, {forward_message, Name, ServerRef, Message}, infinity).

%% @doc Receive message from a remote manager.
receive_message(Message) ->
    gen_server:call(?MODULE, {receive_message, Message}, infinity).

%% @doc Attempt to join a remote node.
join(Node) ->
    gen_server:call(?MODULE, {join, Node}, infinity).

%% @doc Leave the cluster.
leave() ->
    gen_server:call(?MODULE, leave, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    %% Seed the process at initialization.
    random:seed(erlang:phash2([node()]),
                erlang:monotonic_time(),
                erlang:unique_integer()),

    %% Process connection exits.
    process_flag(trap_exit, true),

    %% Schedule periodic gossip.
    schedule_gossip(),

    Actor = gen_actor(),
    Membership = maybe_load_state_from_disk(Actor),
    Connections = dict:new(),

    {ok, #state{actor=Actor,
                pending=[],
                membership=Membership,
                connections=Connections}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.

handle_call(leave, _From,
            #state{actor=Actor,
                   connections=Connections,
                   membership=Membership0}=State) ->
    %% We may exist in the membership on multiple ports, so we need to
    %% remove all.
    Membership = lists:foldl(fun({Node, _, _}, L0) ->
                        case node() of
                            Node ->
                                {ok, L} = ?SET:update({remove, node()}, Actor, L0),
                                L;
                            _ ->
                                L0
                        end
                end, Membership0, ?SET:value(Membership0)),

    %% Gossip.
    do_gossip(Membership, Connections),

    %% Remove state.
    delete_state_from_disk(),

    %% Shutdown; connections terminated on shutdown.
    {stop, normal, State#state{membership=Membership}};

handle_call({join, {Name, _, _}=Node},
            _From,
            #state{pending=Pending0, connections=Connections0}=State) ->
    %% Attempt to join via disterl for control messages during testing.
    _ = net_kernel:connect(Name),

    %% Add to list of pending connections.
    Pending = [Node|Pending0],

    %% Trigger connection.
    Connections = maybe_connect(Node, Connections0),

    %% Return.
    {reply, ok, State#state{pending=Pending,
                            connections=Connections}};

handle_call({send_message, Name, Message}, _From,
            #state{connections=Connections}=State) ->
    Result = do_send_message(Name, Message, Connections),
    {reply, Result, State};

handle_call({forward_message, Name, ServerRef, Message}, _From,
            #state{connections=Connections}=State) ->
    Result = do_send_message(Name,
                             {forward_message, ServerRef, Message},
                             Connections),
    {reply, Result, State};

handle_call({receive_message, Message}, _From, State) ->
    handle_message(Message, State);

handle_call(members, _From, #state{membership=Membership}=State) ->
    Members = [P || {P, _, _} <- members(Membership)],
    {reply, {ok, Members}, State};

handle_call(get_local_state, _From, #state{membership=Membership}=State) ->
    {reply, {ok, Membership}, State};

handle_call(get_actor, _From, #state{actor=Actor}=State) ->
    {reply, {ok, Actor}, State};

handle_call({update_state, NewState}, _From,
            #state{pending=Pending,
                   membership=Membership,
                   connections=Connections0}=State) ->
    Merged = ?SET:merge(Membership, NewState),
    persist_state(Merged),
    Connections = establish_connections(Pending, Membership, Connections0),
    {reply, ok, State#state{membership=Merged, connections=Connections}};

handle_call(delete_state, _From, State) ->
    delete_state_from_disk(),
    {reply, ok, State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(gossip, #state{pending=Pending,
                           membership=Membership,
                           connections=Connections0}=State) ->
    Connections = establish_connections(Pending, Membership, Connections0),
    do_gossip(Membership, Connections),
    schedule_gossip(),
    {noreply, State#state{connections=Connections}};

handle_info({'EXIT', From, _Reason}, #state{connections=Connections0}=State) ->
    FoldFun = fun(K, V, AccIn) ->
                      case V =:= From of
                          true ->
                              dict:erase(K, AccIn);
                          false ->
                              AccIn
                      end
              end,
    Connections = dict:fold(FoldFun, Connections0, Connections0),
    {noreply, State#state{connections=Connections}};

handle_info({connected, Node, RemoteState},
               #state{pending=Pending0,
                      membership=Membership0,
                      connections=Connections}=State) ->
    case lists:member(Node, Pending0) of
        true ->
            %% Move out of pending.
            Pending = Pending0 -- [Node],

            %% Update membership by joining with remote membership.
            Membership = ?SET:merge(RemoteState, Membership0),

            %% Announce to the peer service.
            partisan_peer_service_events:update(Membership),

            %% Gossip the new membership.
            do_gossip(Membership, Connections),

            %% Return.
            {noreply, State#state{pending=Pending,
                                  membership=Membership}};
        false ->
            {noreply, State}
    end;

handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, #state{connections=Connections}=_State) ->
    dict:map(fun(_K, Pid) ->
                     try
                         gen_server:stop(Pid, normal, infinity)
                     catch
                         _:_ ->
                             ok
                     end
             end, Connections),
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
empty_membership(Actor) ->
    Port = partisan_config:get(peer_port, ?PEER_PORT),
    IPAddress = partisan_config:get(peer_ip, ?PEER_IP),
    Self = {node(), IPAddress, Port},
    {ok, LocalState} = ?SET:update({add, Self}, Actor, ?SET:new()),
    persist_state(LocalState),
    LocalState.

%% @private
gen_actor() ->
    Node = atom_to_list(node()),
    Unique = time_compat:unique_integer([positive]),
    TS = integer_to_list(Unique),
    Term = Node ++ TS,
    crypto:hash(sha, Term).

%% @private
data_root() ->
    case application:get_env(partisan, partisan_data_dir) of
        {ok, PRoot} ->
            filename:join(PRoot, "peer_service");
        undefined ->
            undefined
    end.

%% @private
write_state_to_disk(State) ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            ok = file:write_file(File, ?SET:to_binary(State))
    end.

%% @private
delete_state_from_disk() ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            case file:delete(File) of
                ok ->
                    lager:info("Leaving cluster, removed cluster_state");
                {error, Reason} ->
                    lager:info("Unable to remove cluster_state for reason ~p", [Reason])
            end
    end.

%% @private
maybe_load_state_from_disk(Actor) ->
    case data_root() of
        undefined ->
            empty_membership(Actor);
        Dir ->
            case filelib:is_regular(filename:join(Dir, "cluster_state")) of
                true ->
                    {ok, Bin} = file:read_file(filename:join(Dir, "cluster_state")),
                    {ok, State} = ?SET:from_binary(Bin),
                    State;
                false ->
                    empty_membership(Actor)
            end
    end.

%% @private
persist_state(State) ->
    write_state_to_disk(State).

%% @private
members(Membership) ->
    ?SET:value(Membership).

%% @private
establish_connections(Pending, Membership, Connections) ->
    %% Reconnect disconnected members and members waiting to join.
    Members = members(Membership),
    AllPeers = lists:keydelete(node(), 1, Members ++ Pending),
    lists:foldl(fun maybe_connect/2, Connections, AllPeers).

%% @private
%% Function should enforce the invariant that all cluster members are
%% keys in the dict pointing to undefined if they are disconnected or a
%% socket pid if they are connected.
%%
maybe_connect({Name, _, _} = Node, Connections0) ->
    Connections = case dict:find(Name, Connections0) of
        %% Found in dict, and disconnected.
        {ok, undefined} ->
            case connect(Node) of
                {ok, Pid} ->
                    dict:store(Name, Pid, Connections0);
                _ ->
                    dict:store(Name, undefined, Connections0)
            end;
        %% Found in dict and connected.
        {ok, _Pid} ->
            Connections0;
        %% Not present; disconnected.
        error ->
            case connect(Node) of
                {ok, Pid} ->
                    dict:store(Name, Pid, Connections0);
                _ ->
                    dict:store(Name, undefined, Connections0)
            end
    end,
    Connections.

%% @private
connect(Node) ->
    Self = self(),
    partisan_peer_service_client:start_link(Node, Self).

%% @private
handle_message({receive_state, PeerMembership},
               #state{pending=Pending, membership=Membership, connections=Connections0}=State) ->
    NewMembership = case ?SET:equal(PeerMembership, Membership) of
        true ->
            %% No change.
            Membership;
        false ->
            %% Merge data items.
            Merged = ?SET:merge(PeerMembership, Membership),
            partisan_peer_service_events:update(Merged),

            %% Establish any new connections.
            Connections = establish_connections(Pending, Membership, Connections0),

            %% Gossip.
            do_gossip(Membership, Connections),

            Merged
    end,
    {reply, ok, State#state{membership=NewMembership}};
handle_message({forward_message, ServerRef, Message}, State) ->
    gen_server:cast(ServerRef, Message),
    {reply, ok, State}.

%% @private
schedule_gossip() ->
    erlang:send_after(?GOSSIP_INTERVAL, ?MODULE, gossip).

%% @private
do_gossip(Membership, Connections) ->
    Fanout = partisan_config:get(fanout, ?FANOUT),

    case get_peers(Membership) of
        [] ->
            ok;
        AllPeers ->
            {ok, Peers} = random_peers(AllPeers, Fanout),
            lists:foreach(fun(Peer) ->
                        do_send_message(Peer,
                                        {receive_state, Membership},
                                        Connections)
                end, Peers),
            ok
    end.

%% @private
get_peers(Local) ->
    Members = ?SET:value(Local),
    Peers = [X || {X, _, _} <- Members, X /= node()],
    Peers.

%% @private
random_peers(Peers, Fanout) ->
    Shuffled = shuffle(Peers),
    Peer = lists:sublist(Shuffled, Fanout),
    {ok, Peer}.

%% @private
do_send_message(Name, Message, Connections) ->
    %% Find a connection for the remote node, if we have one.
    case dict:find(Name, Connections) of
        {ok, undefined} ->
            %% Node was connected but is now disconnected.
            {error, disconnected};
        {ok, Pid} ->
            gen_server:cast(Pid, {send_message, Message});
        error ->
            %% Node has not been connected yet.
            {error, not_yet_connected}
    end.

%% @reference %% http://stackoverflow.com/questions/8817171/shuffling-elements-in-a-list-randomly-re-arrange-list-elements/8820501#8820501
shuffle(L) ->
    [X || {_, X} <- lists:sort([{random:uniform(), N} || N <- L])].
