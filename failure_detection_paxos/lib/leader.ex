# Modified by Szymon Kubica (sk4520) 18 Feb 2023
defmodule Leader do
  @compile if Mix.env() == :test, do: :export_all

  # ____________________________________________________________________ Setters

  defp add_proposal(self, proposal) do
    %{self | proposals: MapSet.put(self.proposals, proposal)}
  end

  defp activate(self) do
    %{self | active: true}
  end

  defp deactivate(self) do
    %{self | active: false}
  end

  defp update_ballot_number(self, new_value) do
    %{
      self
      | ballot_num: %BallotNumber{self.ballot_num | value: new_value + 1}
    }
  end

  defp increase_timeout(self) do
    base_value = max(self.timeout, self.config.initial_leader_timeout)

    new_timeout =
      min(
        self.config.max_leader_timeout,
        round(base_value * self.config.leader_timeout_increase_factor)
      )

    self
    |> update_timeout(new_timeout)
    |> Monitor.notify(:TIMEOUT_INCREASED, self.timeout)
  end

  defp decrease_timeout(self) do
    new_timeout =
      max(
        self.config.min_leader_timeout,
        self.timeout - self.config.leader_timeout_decrease_const
      )

    self
    |> update_timeout(new_timeout)
    |> Monitor.notify(:TIMEOUT_DECREASED, self.timeout)
  end

  defp update_timeout(self, new_timeout) do
    %{self | timeout: new_timeout}
  end

  # ____________________________________________________________________________

  def start(config) do
    {acceptors, replicas} =
      receive do
        {:BIND, acceptors, replicas} -> {acceptors, replicas}
      end

    self = %{
      type: :leader,
      config: config,
      ballot_num: %BallotNumber{value: 0, leader: self()},
      timeout: config.initial_leader_timeout,
      acceptors: acceptors,
      replicas: replicas,
      failure_detector: nil,
      active: false,
      proposals: MapSet.new()
    }

    self
    |> spawn_scout
    |> spawn_failure_detector
    |> next
  end

  def next(self) do
    receive do
      {:RESPONSE_REQUESTED, requestor} ->
        cond do
          self.active ->
            send(requestor, {:STILL_ALIVE, self.ballot_num, self.timeout})

          true ->
            :skip
        end

        self
        |> Monitor.notify(:PING_RESPONSE_SENT)
        |> next

      {:PROPOSE, s, c} ->
        self = self |> Debug.log("PROPOSE received: command: #{inspect(c)} in slot #{s}")

        if self |> exists_proposal_for?(s), do: self |> next

        proposal = {s, c}

        self =
          self
          |> Debug.log("Slot #{s} empty, adding a proposal: #{inspect({s, c})}")
          |> add_proposal(proposal)
          |> Debug.log("Proposals: #{MapSet.size(self.proposals)} \n #{inspect(self.proposals)}")

        if not self.active, do: self |> next

        self
        |> spawn_commander({self.ballot_num, s, c})
        |> Debug.log("Commander spawned for: #{inspect(c)} in slot #{s}", :success)
        |> next

      {:PROPOSAL_CHOSEN} ->
        self
        |> decrease_timeout
        |> next

      {:ADOPTED, b, pvalues} ->
        if not BallotNumber.equal?(b, self.ballot_num), do: self |> next

        self =
          self
          |> Debug.log("ADOPTED received: ballot: #{inspect(b)}", :success)
          |> Debug.log(
            "Proposals before update #{inspect(self.proposals)}\n" <>
              "--> Pvalues: #{inspect(pvalues)}\n" <>
              "--> Pmax: #{inspect(pmax(pvalues))}"
          )
          |> update_proposals(pmax(pvalues))
          |> Debug.log("Proposals after update #{inspect(self.proposals)}")

        commander_spawning_logs =
          for {s, c} <- self.proposals, into: [] do
            spawn_commander(self, {b, s, c})
            "Commander spawned: command: #{inspect(c)} in slot #{s}"
          end

        self
        |> Debug.log(Enum.join(commander_spawning_logs, "\n--> "))
        |> activate
        |> next

      {:PREEMPTED, %BallotNumber{value: value} = b} ->
        self = self |> Debug.log("Received PREEMPTED message for ballot #{inspect(b)}", :error)

        case self.config.operation_mode do
          :no_liveness ->
            if BallotNumber.less_or_equal?(b, self.ballot_num), do: self |> next

            self
            |> update_ballot_number(value)
            |> spawn_scout

          :partial_liveness ->
            if BallotNumber.less_or_equal?(b, self.ballot_num), do: self |> next

            Process.sleep(
              Enum.random(self.config.min_random_timeout..self.config.max_random_timeout)
            )

            self
            |> update_ballot_number(value)
            |> spawn_scout

          :simplified_liveness ->
            send(self.failure_detector, {:PING, b})
            self

          :full_liveness ->
            send(self.failure_detector, {:PING, b})
            self
        end
        |> deactivate
        |> next

      {:PREEMPT, %BallotNumber{value: value} = b} ->
        if BallotNumber.less_or_equal?(b, self.ballot_num), do: self |> next

        self
        |> increase_timeout
        |> update_ballot_number(value)
        |> spawn_scout
        |> next
    end
  end

  defp spawn_failure_detector(self) do
    failure_detector =
      case self.config.operation_mode do
        :full_liveness ->
          spawn(FailureDetector, :start, [
            self.config,
            self()
          ])

        :simplified_liveness ->
          spawn(SimpleFailureDetector, :start, [
            self.config,
            self()
          ])
      end

    self = self |> Monitor.notify(:FAILURE_DETECTOR_SPAWNED)
    %{self | failure_detector: failure_detector}
  end

  defp spawn_commander(self, {b, s, c}) do
    spawn(Commander, :start, [
      self.config,
      self(),
      self.acceptors,
      self.replicas,
      %Pvalue{ballot_num: b, slot_num: s, command: c}
    ])

    self |> Monitor.notify(:COMMANDER_SPAWNED)
  end

  defp spawn_scout(self) do
    spawn(Scout, :start, [self.config, self(), self.acceptors, self.ballot_num])

    self |> Monitor.notify(:SCOUT_SPAWNED)
  end

  defp exists_proposal_for?(self, slot_number) do
    proposals = for {^slot_number, _c} = proposal <- self.proposals, do: proposal
    length(proposals) > 0
  end

  defp update_proposals(self, max_pvals) do
    remaining_proposals =
      for {s, _c} = proposal <- self.proposals,
          not update_exists?(s, max_pvals),
          into: MapSet.new(),
          do: proposal

    %{self | proposals: MapSet.union(max_pvals, remaining_proposals)}
  end

  defp update_exists?(slot_number, proposals) do
    updates = for {^slot_number, _c} = proposal <- proposals, do: proposal
    length(updates) != 0
  end

  defp pmax(pvalues) do
    for %Pvalue{ballot_num: b, slot_num: s, command: c} <- pvalues,
        Enum.all?(
          for %Pvalue{ballot_num: b1, slot_num: ^s} <- pvalues,
              do: BallotNumber.less_or_equal?(b1, b)
        ),
        into: MapSet.new(),
        do: {s, c}
  end
end
