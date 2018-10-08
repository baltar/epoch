%% Test that we can syn generations with a lot of micro blocks and transactions
%% This test is expensive to run, because we run some real mining.
%% But it is useful in finding timing related errors in sync

-module(aecore_txs_many_SUITE).

%% common_test exports
-export(
   [
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
   ]).

%% test case exports
-export(
   [ micro_blocks/1
   ]).


-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [ micro_blocks ].

init_per_suite(Config) ->
    ok = application:ensure_started(erlexec),
    DataDir = ?config(data_dir, Config),
    TopDir = aecore_suite_utils:top_dir(DataDir),
    MicroBlockCycle = 3000,   %% with fast mining, only one block per keyblock
    Config1 = [{symlink_name, "latest.txsmany"},
               {top_dir, TopDir},
               {test_module, ?MODULE},
               {micro_block_cycle, MicroBlockCycle}] ++ Config,
    aecore_suite_utils:make_shortcut(Config1),
    ct:log("Environment = ~p", [[{args, init:get_arguments()},
                                 {node, node()},
                                 {cookie, erlang:get_cookie()}]]),
    DefCfg = #{
        <<"chain">> => #{
            <<"persist">> => false
        }
        , <<"mining">> => #{
            <<"expected_mine_rate">> => 180000,
            <<"micro_block_cycle">> => MicroBlockCycle,
            <<"cuckoo">> =>
               #{ 
                  <<"miner">> => 
                      #{ <<"executable">> => <<"mean28s-generic">>,
                         <<"extra_args">> => <<"">>,
                         <<"node_bits">> => 28} 
                }
          }
    },
    aecore_suite_utils:create_configs(Config1, DefCfg),
    aecore_suite_utils:make_multi(Config1),
    [{nodes, [aecore_suite_utils:node_tuple(dev1),
              aecore_suite_utils:node_tuple(dev2)]} | Config1].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    ct:log("testcase pid: ~p", [self()]),
    [{tc_start, os:timestamp()}|Config].

end_per_testcase(_Case, Config) ->
    %% Ts0 = ?config(tc_start, Config),
    %% ct:log("Events during TC: ~p", [[{N, aecore_suite_utils:all_events_since(N, Ts0)}
    %%                                  || {_,N} <- ?config(nodes, Config)]]),
    aecore_suite_utils:stop_node(dev1, Config),
    aecore_suite_utils:stop_node(dev2, Config),
    ok.

%% ============================================================
%% Test cases
%% ============================================================
micro_blocks(Config) ->
    aecore_suite_utils:start_node(dev1, Config),
    N1 = aecore_suite_utils:node_name(dev1),
    aecore_suite_utils:connect(N1),

    TxsPerMB = aec_governance:block_gas_limit() div aec_governance:tx_base_gas(spend_tx),
    ct:log("We can put ~p Txs in a micro block\n", [TxsPerMB]),

    %% Add a bunch of transactions...
    Txs1 = add_spend_txs(N1, <<"greetings">>, 4000, 1),
    ExpectedMBs1 = (length(Txs1) div TxsPerMB) + 1,
    ct:log("filled pool with ~p transactions\n", [length(Txs1)]),    

    %% Mine a block with as many Txs as possible
    %% Since we mine on top speed, we may change leader to ourself a number of times, creating more keyblocks than 
    %% probably expected.
    {ok, _} = aecore_suite_utils:mine_blocks_until_txs_on_chain(N1, [lists:last(Txs1)], round(ExpectedMBs1 * 1.5) + 5),


    Top = aec_blocks:height(rpc:call(N1, aec_chain, top_block, [])),

    ct:log("Explored ~p", [explorer(N1, 0)]),
    ct:log("Top reached ~p", [Top]),

    aecore_suite_utils:start_node(dev2, Config),
    N2 = aecore_suite_utils:node_name(dev2),
    aecore_suite_utils:connect(N2),

    aecore_suite_utils:wait_for_height(N2, min(Top, 100)), 
    ok.


explorer(Node, N) ->
    case rpc:call(Node, aec_chain, get_generation_by_height, [N, forward]) of
        error -> %% end of chain reached
            [];
        {ok, #{micro_blocks := MBs}} ->
            [{N, [ {txs,  length(aec_blocks:txs(MB))} || MB <- MBs]} | explorer(Node, N + 1)]
    end.

pool_peek(Node) ->
    rpc:call(Node, sys, get_status, [aec_tx_pool_gc]),
    rpc:call(Node, aec_tx_pool, peek, [infinity]).


add_spend_txs(Node, Payload, N, NonceStart) ->
    From = patron(),
    To = new_pubkey(),
    [ add_spend_tx(Node, Payload, Nonce, From, To) || Nonce <- lists:seq(NonceStart, NonceStart + N - 1) ].

add_spend_tx(Node, Payload, Nonce, Sender, Recipient) ->
    SenderId = aec_id:create(account, maps:get(pubkey, Sender)),
    RecipientId = aec_id:create(account, Recipient),
    Params = #{ sender_id    => SenderId,
                recipient_id => RecipientId,
                amount       => 10,
                nonce        => Nonce,
                ttl          => 10000,
                payload      => Payload,
                fee          => 1 },
    {ok, Tx} = aec_spend_tx:new(Params),
    STx = aec_test_utils:sign_tx(Tx, maps:get(privkey, Sender)),
    ok = rpc:call(Node, aec_tx_pool, push, [STx]),
    aec_base58c:encode(tx_hash, aetx_sign:hash(STx)).

new_pubkey() ->
    #{ public := PubKey } = enacl:sign_keypair(),
    PubKey.

patron() ->
    #{ pubkey  => <<206,167,173,228,112,201,249,157,157,78,64,8,128,168,111,29,
                    73,187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>,
       privkey => <<230,169,29,99,60,119,207,87,113,50,157,51,84,179,188,239,27,
                    197,224,50,196,61,112,182,211,90,249,35,206,30,183,77,206,
                    167,173,228,112,201,249,157,157,78,64,8,128,168,111,29,73,
                    187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>
      }.
