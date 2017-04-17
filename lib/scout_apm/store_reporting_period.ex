defmodule ScoutApm.StoreReportingPeriod do
  require Logger

  alias ScoutApm.Internal.Duration
  alias ScoutApm.Internal.Trace
  alias ScoutApm.MetricSet
  alias ScoutApm.ScoredItemSet

  def start_link(timestamp) do
    Agent.start_link(fn ->
      %{
        time: beginning_of_minute(timestamp),
        metric_set: MetricSet.new(),
        traces: ScoredItemSet.new(),
        histograms: %{}, # a map of key => ApproximateHistogram
      }
    end)
  end

  def record_trace(pid, trace) do
    Agent.update(pid,
      fn state ->
        %{state | traces: ScoredItemSet.absorb(state.traces, Trace.as_scored_item(trace))}
      end
    )
  end

  def record_metric(pid, metric) do
    Agent.update(pid,
      fn state ->
        %{state | metric_set: MetricSet.absorb(state.metric_set, metric)}
      end
    )
  end

  def record_timing(pid, key, %Duration{} = timing), do: record_timing(pid, key, Duration.as(timing, :seconds))
  def record_timing(pid, key, timing) do
    Agent.update(pid,
      fn state ->
        %{state | histograms:
          Map.update(state.histograms, key, ApproximateHistogram.new(), fn histo ->
            ApproximateHistogram.add(histo, timing)
          end)}
      end
    )
  end

  # Returns true if the timestamp is part of the minute of this StoreReportingPeriod
  def covers?(pid, timestamp) do
    t = Agent.get(pid, fn state -> state.time end)

    NaiveDateTime.compare(t, beginning_of_minute(timestamp)) == :eq
  end

  # How many seconds from the "beginning of minute" time until we say that its
  # ok to report this reporting period?
  @reporting_age 60

  # Returns :ready | :not_ready depending on if this reporting periods time is now past
  def ready_to_report?(pid) do
    t = Agent.get(pid, fn state -> state.time end)
    now = NaiveDateTime.utc_now()

    diff = NaiveDateTime.diff(now, t, :seconds)

    if diff > @reporting_age do
      :ready
    else
      :not_ready
    end
  end

  # Pushes all data from the agent outward to the reporter.
  # Then stops the underlying process holding that info.  This must be the last
  # call to this ReportingPeriod, it is a stopped process after this.
  def report!(pid) do
    try do
      state = Agent.get(pid, fn state -> state end)
      Agent.stop(pid)

      payload = ScoutApm.Payload.new(
        state.time,
        state.metric_set,
        ScoredItemSet.to_list(state.traces, :without_scores),
        state.histograms
      )
      Logger.info("Reporting: Payload created with data from #{ScoutApm.Payload.total_call_count(payload)} requests.")
      Logger.debug("Payload #{inspect payload}")

      encoded = ScoutApm.Payload.encode(payload)
      ScoutApm.Reporter.post(encoded)
    rescue
      e in RuntimeError -> Logger.info("Reporting runtime error: #{inspect e}")
      e -> Logger.info("Reporting other error: #{inspect e}")
    end
  end

  defp beginning_of_minute(datetime) do
    {date, {hour, minute, _}} = NaiveDateTime.to_erl(datetime)
    {:ok, beginning} = NaiveDateTime.from_erl({date, {hour, minute, 0}})
    beginning
  end
end
