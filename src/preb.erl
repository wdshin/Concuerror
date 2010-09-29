%%%----------------------------------------------------------------------
%%% File        : preb.erl
%%% Authors     : Alkis Gotovos <el3ctrologos@hotmail.com>
%%%               Maria Christakis <christakismaria@gmail.com>
%%% Description : Preemption bounding
%%% Created     : 28 Sep 2010
%%%----------------------------------------------------------------------

-module(preb).

-export([interleave/1]).

-include("gen.hrl").

%% Produce all possible process interleavings of (Mod, Fun, Args).
%% Options:
%%   {init_state, InitState}: State to replay (default: state_init()).
%%   details: Produce detailed interleaving information (see `replay_logger`).
-spec interleave(sched:analysis_target()) -> sched:analysis_ret().

interleave(Target) ->
    interleave(Target, [{init_state, state:empty()}]).

interleave(Target, Options) ->
    Self = self(),
    %% TODO: Need spawn_link?
    spawn(fun() -> interleave_aux(Target, Options, Self) end),
    receive
	{interleave_result, Result} -> Result
    end.

interleave_aux(Target, Options, Parent) ->
    {init_state, InitState} = lists:keyfind(init_state, 1, Options),
    Det = lists:member(details, Options),
    register(?RP_SCHED, self()),
    %% The mailbox is flushed mainly to discard possible `exit` messages
    %% before enabling the `trap_exit` flag.
    util:flush_mailbox(),
    process_flag(trap_exit, true),
    %% Start state service.
    state_start(),
    %% Save empty replay state for the first run.
    state_save(InitState),
    Result = interleave_outer_loop(Target, 0, [], Det),
    state_stop(),
    unregister(?RP_SCHED),
    Parent ! {interleave_result, Result}.

%% Outer analysis loop.
%% Preemption bound starts at 0 and is increased by 1 on each iteration.
interleave_outer_loop(Target, RunCnt, Tickets, Det) ->
    {NewRunCnt, NewTickets} = interleave_loop(Target, 1, [], Det),
    TotalRunCnt = NewRunCnt + RunCnt,
    TotalTickets = NewTickets ++ Tickets,
    state_swap(),
    case state_peak() of
	no_state ->
	    case TotalTickets of
		[] -> {ok, TotalRunCnt};
		_Any -> {error, TotalRunCnt, ticket:sort(TotalTickets)}
	    end;
	_State -> interleave_outer_loop(Target, TotalRunCnt, TotalTickets, Det)
    end.

%% Main loop for producing process interleavings.
%% The first process (FirstPid) is created linked to the scheduler,
%% so that the latter can receive the former's exit message when it
%% terminates. In the same way, every process that may be spawned in
%% the course of the program shall be linked to the scheduler process.
interleave_loop(Target, RunCnt, Tickets, Det) ->
    %% Lookup state to replay.
    case state_load() of
        no_state -> {RunCnt - 1, Tickets};
        ReplayState ->
            ?debug_1("Running interleaving ~p~n", [RunCnt]),
            ?debug_1("----------------------~n"),
            lid:start(),
	    %% Spawn initial process.
	    {Mod, Fun, Args} = Target,
	    NewFun = fun() -> sched:wait(), apply(Mod, Fun, Args) end,
            FirstPid = spawn_link(NewFun),
            FirstLid = lid:new(FirstPid, noparent),
	    %% Initialize scheduler context.
            Active = sets:add_element(FirstLid, sets:new()),
            Blocked = sets:new(),
            State = state:empty(),
	    Context = #context{active = Active, blocked = Blocked,
                               state = State, details = Det},
	    Search = fun(C) -> search(C) end,
	    %% Interleave using driver.
            Ret = sched:driver(Search, Context, ReplayState),
	    %% Cleanup.
            lid:stop(),
	    ?debug_1("-----------------------~n"),
	    ?debug_1("Run terminated.~n~n"),
	    %% TODO: Proper cleanup of any remaining processes.
            case Ret of
                ok -> interleave_loop(Target, RunCnt + 1, Tickets, Det);
                {error, Error, ErrorState} ->
		    Ticket = ticket:new(Target, Error, ErrorState),
		    interleave_loop(Target, RunCnt + 1, [Ticket|Tickets], Det)
            end
    end.

%% Implements the search logic (currently depth-first when looked at combined
%% with the replay logic).
%% Given a blocked state (no process running when called), creates all
%% possible next states, chooses one of them for running and inserts the rest
%% of them into the `states` table.
%% Returns the process to be run next.
search(#context{active = Active, state = State}) ->
    case state:is_empty(State) of
	%% Handle first call to search (empty state, one active process).
	true ->
	    [Next] = sets:to_list(Active),
	    Next;
	false ->
	    %% Get last process that was run by the driver.
	    {LastLid, _Rest} = state:trim(State),
	    %% If that process is in the `active` set (i.e. has not blocked),
	    %% remove it from the actives and make it next-to-run, else do
	    %% that for another process from the actives.
	    {Next, NewActive} =
		case sets:is_element(LastLid, Active) of
		    true -> {LastLid,
			     sets:to_list(sets:del_element(LastLid, Active))};
		    false ->
			[INext|INewActive] = sets:to_list(Active),
			{INext, INewActive}
		end,
	    %%io:format("Search - NewActive: ~p~n", [NewActive]),
	    %% Store all other possible successor states for later exploration.
	    [state_save(state:extend(State, Lid)) || Lid <- NewActive],
	    Next
    end.

%%%----------------------------------------------------------------------
%%% Helper functions
%%%----------------------------------------------------------------------

%% Remove and return a state.
%% If no states available, return 'no_state'.
state_load() ->
    case ets:first(?NT_STATE1) of
	'$end_of_table' -> no_state;
	State ->
	    ets:delete(?NT_STATE1, State),
	    lists:reverse(State)
    end.

%% Return a state without remoing it.
%% If no states available, return 'no_state'.
state_peak() ->
    case ets:first(?NT_STATE1) of
	'$end_of_table' ->  no_state;
	State -> lists:reverse(State)
    end.

%% Add a state to the `state` table.
state_save(State) ->
    ets:insert(?NT_STATE2, {State}).

%% Initialize state tables.
state_start() ->
    ets:new(?NT_STATE1, [named_table]),
    ets:new(?NT_STATE2, [named_table]).

%% Clean up state table.
state_stop() ->
    ets:delete(?NT_STATE1),
    ets:delete(?NT_STATE2).

%% Swap names of the two state tables and clear one of them.
state_swap() ->
    ets:rename(?NT_STATE1, ?NT_STATE_TEMP),
    ets:rename(?NT_STATE2, ?NT_STATE1),
    ets:rename(?NT_STATE_TEMP, ?NT_STATE2),
    ets:delete_all_objects(?NT_STATE2).