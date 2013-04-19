%% A Banker in the Banker's Algorithm.
%% Author: Andrew Garrett
-module(banker).
-export([start/1, status/0, attach/1, request/1, release/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%%  Banker data structure
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% The Banker's data.
%%  capital: the initial capital of the bank; the total amount of resources
%%           which will be available
%%  cash_on_hand: the amount of resources not yet lent.
%%  clients: a list of Clients (their pids)
-record(banker,
        { capital :: non_neg_integer()
        , cash_on_hand :: non_neg_integer()
        , client_procs = [] :: list(pid())
        }).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%%  Client functions (send messages to the server)
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% start/1
%% Spawns the Banker process and registers it with the atom banker.
%% Arguments:
%%  Capital - the specified capital amount with which to begin
start(Capital) ->
    Banker = #banker{capital = Capital, cash_on_hand = Capital},
    register(banker, spawn(fun() -> main(Banker) end)).

%% status/0
%% Reports the status of the system.
%% Returns:
%%  {Capital, CashOnHand, NClients}
status() ->
    case whereis(banker) of
        unregistered ->
            throw(banker_not_registered);
        _ ->
            banker ! {self(), status},
            receive
                {Capital, CashOnHand, NClients} ->
                    {Capital, CashOnHand, NClients}
            end
    end.

%% attach/1
%% A Client attaches to the Banker.
%% Arguments:
%%  Limit: the maximum number of resources the Client can request.
attach(Limit) ->
    case whereis(banker) of
        unregistered ->
            throw(banker_not_registered);
        _ ->
            banker ! {self(), attach, Limit}
    end.

%% request/1
%% An attached Client requests more resources from the Banker.
%% Arguments:
%%  NUnits: the number of resources requested.
request(NUnits) ->
    case whereis(banker) of
        unregistered ->
            throw(banker_not_registered);
        _ ->
            banker ! {self(), request, NUnits}
    end.

%% release/1
%% An attached Client releases resources to the Banker.
%% Arguments:
%%  NUnits: the number of resources released.
release(NUnits) ->
    case whereis(banker) of
        unregistered ->
            throw(banker_not_registered);
        _ ->
            banker ! {self(), release, NUnits}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%%  Server functions (run the bank)
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% main/1
%% Run the Bank.
%% Arguments:
%%  Banker: the #banker record
main(Banker) ->
    process_flag(trap_exit, true),
    Capital = Banker#banker.capital,
    CashOnHand = Banker#banker.cash_on_hand,
    ClientProcs = Banker#banker.client_procs,
    receive
        {Pid, status} ->
            io:format(  "Banker status was requested. CashOnHand = ~p, 
                        ClientProcs = ~p.~n"
                        , [CashOnHand, ClientProcs]),
            Pid ! { Capital, CashOnHand, length(ClientProcs)},
            main(Banker);
        {Pid, attach, Limit} when Limit =< Capital ->
            NewBanker = #banker { capital = Capital
                                , cash_on_hand = CashOnHand
                                , client_procs = [Pid | ClientProcs]
                                },
            link(Pid),
            main(NewBanker);
        {_Pid, attach, _Limit} ->
            throw(limit_exceeds_capital);
        {Pid, request, NUnits} ->
            %Clients = get_clients(ClientProcs),
            Compare_Clients = fun(C1, C2) -> compare_clients(C1, C2) end,
            lists:sort(Compare_Clients, ClientProcs),
            NewBanker = case is_safe_state(ClientProcs, CashOnHand) of
                true ->
                    Pid ! ok,
                    #banker { capital = Capital
                            , cash_on_hand = CashOnHand - NUnits
                            , client_procs = ClientProcs
                            };
                false ->
                    Pid ! {self(), unsafe}
            end,
            main(NewBanker);
        {_Pid, release, NUnits} ->
            NewBanker = #banker { capital = Capital
                                , cash_on_hand = CashOnHand + NUnits
                                , client_procs = ClientProcs
                                },
            io:format(  "Banker is notifying waiting Clients to try again.~n"
                        , []),
            notify_waiting_clients(),
            main(NewBanker);
        {'EXIT', Pid, {finished, Loan}} ->
            io:format(  "Banker reclaims ~p resources from exiting Client ~p.~n"
                        , [Loan, Pid]),
            NewBanker = #banker { capital = Capital
                                , cash_on_hand = CashOnHand + Loan
                                , client_procs = lists:delete(Pid, ClientProcs)
                                },
            main(NewBanker)
    %after 0 ->
        %_ ->
        %    throw(unexpected_banker_message)
    end.

%% get_clients/1
%% Get the #client records from a list of Client processes.
%% Arguments:
%%  ClientProcs: the list of Client processes.
%% Returns:
%%  Clients: the list of #client records.
%%get_clients(ClientProcs) -> h_get_clients(ClientProcs, []).
%%h_get_clients([], Clients) -> Clients;
%%h_get_clients([PH | PT], Clients) ->
%%    PH ! {self(), getclient},
%%    receive
%%        {client, Client} ->
%%            NewClients = [Client | Clients]
%%    end,
%%    h_get_clients(PT, NewClients).

    
%% compare_clients/2
%% Defines the sorting order for clients. (From least claim to greatest claim.)
%% Arguments:
%%  C1: a Client record
%%  C2: a different Client record
compare_clients(C1, C2) ->
    C1 ! {self(), getclaim},
    receive
        {claim, C1_claim} -> C1_claim
    end,
    C2 ! {self(), getclaim},
    receive
        {claim, C2_claim} -> C2_claim
    end,
    C1_claim < C2_claim.

%% is_safe_state/2
%% Check the list of Clients and determine if the state is safe.
%% Arguments:
%%  Clients: the list of Clients.
%%  NUnits: the number of resources requested by a Client.
%% Returns:
%%  true if state is safe, false is not.
is_safe_state([], _) ->
    true;
is_safe_state([CH | CT], CashOnHand) ->
    CH ! {self(), getclaim},
    receive
        {claim, Claim} -> Claim
    end,
    CH ! {self(), getloan},
    receive
        {loan, Loan} -> Loan
    end,
    if
        Claim > CashOnHand ->
            false;
        Claim =< CashOnHand ->
            is_safe_state(CT, CashOnHand + Loan)
    end.

%% notify_waiting_clients/0
%% Go through the mailbox and find all messages from Client procs which are
%% waiting to have their requests processed, and tell them to try_again.
%% Returns:
%%  ok when done.
notify_waiting_clients() ->
    receive
        {Pid, waiting} ->
            io:format(  "Banker is notifying waiting Client ~p to retry its
                        request.~n"
                        , [Pid]),
            Pid ! try_again,
            notify_waiting_clients()
    after 0 ->
        io:format(  "Banker has finished notifying waiting Clients.~n", []),
        ok
    end.