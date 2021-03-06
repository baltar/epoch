%%%=============================================================================
%%% @copyright 2017, Aeternity Anstalt
%%% @doc
%%%    Module defining the Oracle register transaction
%%% @end
%%%=============================================================================
-module(aeo_query_tx).

-include("oracle_txs.hrl").

-behavior(aetx).

%% Behavior API
-export([new/1,
         type/0,
         fee/1,
         gas/1,
         ttl/1,
         nonce/1,
         origin/1,
         check/3,
         process/3,
         signers/2,
         version/0,
         serialization_template/1,
         serialize/1,
         deserialize/2,
         for_client/1
        ]).

%% Additional getters
-export([oracle_id/1,
         oracle_pubkey/1,
         query/1,
         query_fee/1,
         query_id/1,
         query_ttl/1,
         response_ttl/1,
         sender_id/1,
         sender_pubkey/1]).


-define(ORACLE_QUERY_TX_VSN, 1).
-define(ORACLE_QUERY_TX_TYPE, oracle_query_tx).

-record(oracle_query_tx, {
          sender_id    :: aec_id:id(),
          nonce        :: integer(),
          oracle_id    :: aec_id:id(),
          query        :: aeo_oracles:query(),
          query_fee    :: integer(),
          query_ttl    :: aeo_oracles:ttl(),
          response_ttl :: aeo_oracles:relative_ttl(),
          fee          :: integer(),
          ttl          :: aetx:tx_ttl()
          }).

-opaque tx() :: #oracle_query_tx{}.

-export_type([tx/0]).

-spec sender_id(tx()) -> aec_id:id().
sender_id(#oracle_query_tx{sender_id = SenderId}) ->
    SenderId.

-spec sender_pubkey(tx()) -> aec_keys:pubkey().
sender_pubkey(#oracle_query_tx{sender_id = SenderId}) ->
    aec_id:specialize(SenderId, account).

-spec oracle_id(tx()) -> aec_id:id().
oracle_id(#oracle_query_tx{oracle_id = OracleId}) ->
    OracleId.

-spec oracle_pubkey(tx()) -> aec_keys:pubkey().
oracle_pubkey(#oracle_query_tx{oracle_id = OracleId}) ->
    aec_id:specialize(OracleId, oracle).

-spec query(tx()) -> aeo_oracles:query().
query(#oracle_query_tx{query = Query}) ->
    Query.

-spec query_fee(tx()) -> integer().
query_fee(#oracle_query_tx{query_fee = QueryFee}) ->
    QueryFee.

-spec query_id(tx()) -> aeo_query:id().
query_id(#oracle_query_tx{} = Tx) ->
    aeo_query:id(sender_pubkey(Tx), nonce(Tx), oracle_pubkey(Tx)).

-spec query_ttl(tx()) -> aeo_oracles:ttl().
query_ttl(#oracle_query_tx{query_ttl = QueryTTL}) ->
    QueryTTL.

-spec response_ttl(tx()) -> aeo_oracles:relative_ttl().
response_ttl(#oracle_query_tx{response_ttl = ResponseTTL}) ->
    ResponseTTL.

-spec new(map()) -> {ok, aetx:tx()}.
new(#{sender_id    := SenderId,
      nonce        := Nonce,
      oracle_id    := OracleId,
      query        := Query,
      query_fee    := QueryFee,
      query_ttl    := QueryTTL,
      response_ttl := ResponseTTL,
      fee          := Fee} = Args) ->
    account = aec_id:specialize_type(SenderId),
    oracle  = aec_id:specialize_type(OracleId), %% TODO: Should also be 'name'
    Tx = #oracle_query_tx{sender_id     = SenderId,
                          nonce         = Nonce,
                          oracle_id     = OracleId,
                          query         = Query,
                          query_fee     = QueryFee,
                          query_ttl     = QueryTTL,
                          response_ttl  = ResponseTTL,
                          fee           = Fee,
                          ttl           = maps:get(ttl, Args, 0)},
    {ok, aetx:new(?MODULE, Tx)}.

-spec type() -> atom().
type() ->
    ?ORACLE_QUERY_TX_TYPE.

-spec fee(tx()) -> integer().
fee(#oracle_query_tx{fee = F}) ->
    F.

-spec gas(tx()) -> non_neg_integer().
gas(#oracle_query_tx{}) ->
    0.

-spec ttl(tx()) -> aetx:tx_ttl().
ttl(#oracle_query_tx{ttl = TTL}) ->
    TTL.

-spec nonce(tx()) -> non_neg_integer().
nonce(#oracle_query_tx{nonce = Nonce}) ->
    Nonce.

-spec origin(tx()) -> aec_keys:pubkey().
origin(#oracle_query_tx{} = Tx) ->
    sender_pubkey(Tx).

%% SenderAccount should exist, and have enough funds for the fee + the query_fee.
%% Oracle should exist, and query_fee should be enough
%% Fee should cover TTL
-spec check(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()} | {error, term()}.
check(#oracle_query_tx{nonce = Nonce, query_fee = QFee, query_ttl = QTTL,
                       fee = Fee} = QTx,
      Trees, Env) ->
    Height       = aetx_env:height(Env),
    SenderPubKey = sender_pubkey(QTx),
    OraclePubKey = oracle_pubkey(QTx),
    Checks =
        [fun() -> aetx_utils:check_account(SenderPubKey, Trees, Nonce, Fee + QFee) end,
         fun() -> check_oracle(OraclePubKey, Trees, Height, QTx) end,
         fun() -> check_query_not_present(QTx, Trees, Height) end
         | case aetx_env:context(Env) of
               aetx_contract -> [];
               aetx_transaction ->
                   [fun() -> aeo_utils:check_ttl_fee(Height, QTTL, Fee - aec_governance:minimum_tx_fee()) end]
           end
        ],

    case aeu_validation:run(Checks) of
        ok              -> {ok, Trees};
        {error, Reason} -> {error, Reason}
    end.

-spec signers(tx(), aec_trees:trees()) -> {ok, [aec_keys:pubkey()]}.
signers(#oracle_query_tx{} = Tx, _) ->
    {ok, [sender_pubkey(Tx)]}.

-spec process(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()}.
process(#oracle_query_tx{nonce = Nonce, fee = Fee,
                         query_fee = QueryFee} = QueryTx,
        Trees0, Env) ->
    Height        = aetx_env:height(Env),
    SenderPubKey  = sender_pubkey(QueryTx),
    AccountsTree0 = aec_trees:accounts(Trees0),
    OraclesTree0  = aec_trees:oracles(Trees0),

    Sender0 = aec_accounts_trees:get(SenderPubKey, AccountsTree0),
    {ok, Sender1} = aec_accounts:spend(Sender0, QueryFee + Fee, Nonce),
    AccountsTree1 = aec_accounts_trees:enter(Sender1, AccountsTree0),

    Query = aeo_query:new(QueryTx, Height),
    OraclesTree1 = aeo_state_tree:insert_query(Query, OraclesTree0),

    Trees1 = aec_trees:set_accounts(Trees0, AccountsTree1),
    Trees2 = aec_trees:set_oracles(Trees1, OraclesTree1),

    {ok, Trees2}.

serialize(#oracle_query_tx{sender_id    = SenderId,
                           nonce        = Nonce,
                           oracle_id    = OracleId,
                           query        = Query,
                           query_fee    = QueryFee,
                           query_ttl    = {QueryTTLType0, QueryTTLValue},
                           response_ttl = {?ttl_delta_atom, ResponseTTLValue},
                           fee          = Fee,
                           ttl          = TTL}) ->
    QueryTTLType = case QueryTTLType0 of
                       ?ttl_delta_atom -> ?ttl_delta_int;
                       ?ttl_block_atom -> ?ttl_block_int
                   end,
    {version(),
     [ {sender_id, SenderId}
     , {nonce, Nonce}
     , {oracle_id, OracleId}
     , {query, Query}
     , {query_fee, QueryFee}
     , {query_ttl_type, QueryTTLType}
     , {query_ttl_value, QueryTTLValue}
     , {response_ttl_type, ?ttl_delta_int}
     , {response_ttl_value, ResponseTTLValue}
     , {fee, Fee}
     , {ttl, TTL}
     ]}.

deserialize(?ORACLE_QUERY_TX_VSN,
            [ {sender_id, SenderId}
            , {nonce, Nonce}
            , {oracle_id, OracleId}
            , {query, Query}
            , {query_fee, QueryFee}
            , {query_ttl_type, QueryTTLType0}
            , {query_ttl_value, QueryTTLValue}
            , {response_ttl_type, ?ttl_delta_int}
            , {response_ttl_value, ResponseTTLValue}
            , {fee, Fee}
            , {ttl, TTL}]) ->
    QueryTTLType = case QueryTTLType0 of
                       ?ttl_delta_int -> ?ttl_delta_atom;
                       ?ttl_block_int -> ?ttl_block_atom
                   end,
    account = aec_id:specialize_type(SenderId),
    oracle = aec_id:specialize_type(OracleId),
    #oracle_query_tx{sender_id    = SenderId,
                     nonce        = Nonce,
                     oracle_id    = OracleId,
                     query        = Query,
                     query_fee    = QueryFee,
                     query_ttl    = {QueryTTLType, QueryTTLValue},
                     response_ttl = {?ttl_delta_atom, ResponseTTLValue},
                     fee          = Fee,
                     ttl          = TTL}.

serialization_template(?ORACLE_QUERY_TX_VSN) ->
    [ {sender_id, id}
    , {nonce, int}
    , {oracle_id, id}
    , {query, binary}
    , {query_fee, int}
    , {query_ttl_type, int}
    , {query_ttl_value, int}
    , {response_ttl_type, int}
    , {response_ttl_value, int}
    , {fee, int}
    , {ttl, int}
    ].

-spec version() -> non_neg_integer().
version() ->
    ?ORACLE_QUERY_TX_VSN.

for_client(#oracle_query_tx{sender_id = SenderId,
                            nonce      = Nonce,
                            oracle_id  = OracleId,
                            query      = Query,
                            query_fee  = QueryFee,
                            fee        = Fee,
                            ttl = TTL} = Tx) ->
    {QueryTLLType, QueryTTLValue} = query_ttl(Tx),
    {ResponseTTLType = delta, ResponseTTLValue} = response_ttl(Tx),
    #{<<"sender_id">>    => aehttp_api_encoder:encode(id_hash, SenderId),
      <<"nonce">>        => Nonce,
      <<"oracle_id">>    => aehttp_api_encoder:encode(id_hash, OracleId),
      <<"query">>        => Query,
      <<"query_fee">>    => QueryFee,
      <<"query_ttl">>    => #{<<"type">>  => QueryTLLType,
                              <<"value">> => QueryTTLValue},
      <<"response_ttl">> => #{<<"type">>  => ResponseTTLType,
                              <<"value">> => ResponseTTLValue},
      <<"fee">>          => Fee,
      <<"ttl">>          => TTL}.

%% -- Local functions  -------------------------------------------------------

check_query_not_present(QTx, Trees, Height) ->
    Oracles = aec_trees:oracles(Trees),
    I       = aeo_query:new(QTx, Height),
    Id      = aeo_query:id(I),
    case aeo_state_tree:lookup_query(oracle_pubkey(QTx), Id, Oracles) of
        none       -> ok;
        {value, _} -> {error, oracle_query_already_present}
    end.

check_oracle(OraclePubKey, Trees, Height,
             #oracle_query_tx{query_fee = QueryFee,
                              query_ttl = QTTL,
                              response_ttl = RTTL
                             } = QTx) ->
    OraclesTree  = aec_trees:oracles(Trees),
    case aeo_state_tree:lookup_oracle(OraclePubKey, OraclesTree) of
        {value, Oracle} ->
            case QueryFee >= aeo_oracles:query_fee(Oracle) of
                true  -> check_oracle_ttl(Oracle, Height, QTTL, RTTL, QTx);
                false -> {error, query_fee_too_low}
            end;
        none -> {error, oracle_does_not_exist}
    end.

check_oracle_ttl(O, Height, QTTL, RTTL, QTx) ->
    try
        Delta  = aeo_utils:ttl_delta(Height, QTTL),
        MaxTTL = aeo_utils:ttl_expiry(Height + Delta, RTTL),
        case aeo_oracles:ttl(O) < MaxTTL of
            false -> check_query_format(O, QTx);
            true  -> {error, too_long_ttl}
        end
    catch _:_ ->
        {error, invalid_ttl}
    end.

check_query_format(O, QTx) ->
    VMVersion =  aeo_oracles:vm_version(O),
    Format = aeo_oracles:query_format(O),
    Content = query(QTx),
    aeo_utils:check_format(VMVersion, Format, Content).
