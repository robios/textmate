#ifndef PREVIEW_COMMAND_RUNNER_H_V8KQ3ZTL
#define PREVIEW_COMMAND_RUNNER_H_V8KQ3ZTL

namespace preview
{
	struct run_result_t
	{
		enum class status_t { success, launch_failed, nonzero_exit, abnormal_exit, timeout, output_overflow, stderr_overflow, invalid_output, cancelled };

		status_t status = status_t::cancelled;
		int exit_code   = 0;
		std::string html;         // the fragment — valid UTF-8, success only
		std::string diagnostic;   // summary line plus bounded stderr, for the reader
	};

	// One external converter run: ‘/bin/sh -c command’ spawned as the leader of
	// a new process group, buffer contents on stdin, the HTML fragment expected
	// on stdout. stdin is pumped while stdout and stderr are drained
	// concurrently, so pipe-buffer back-pressure cannot deadlock the run.
	//
	// wait() blocks until the leader is over and must be called exactly once,
	// not on the main thread. cancel() is safe from any thread and any time:
	// it SIGTERMs the process group (pipelines and grandchildren included),
	// escalates to SIGKILL after a grace period, and makes wait() report a
	// silent ‘cancelled’. The hard timeout runs on its own timer, independent
	// of whichever thread is blocked in wait().
	//
	// The leader’s exit is not the group’s — a converter can leave a background
	// job in there — so the end of the run sweeps the group the same way a
	// cancellation does before giving up the leader’s pid. That pid is the id
	// of the group, and it stays unrecyclable only for as long as the zombie
	// goes unreaped, so the reap is the last act of whichever path ends up
	// facing a group with nothing signalable left in it.
	struct command_runner_t : std::enable_shared_from_this<command_runner_t>
	{
		struct limits_t
		{
			double timeout      = 10;         // seconds until the run is forcibly terminated
			double kill_grace   = 0.5;        // seconds between SIGTERM and SIGKILL
			size_t max_output   = 16 << 20;   // stdout cap — crossing it terminates the group
			size_t max_error    = 1 << 20;    // stderr cap — likewise
		};

		static std::shared_ptr<command_runner_t> launch (std::string const& command, std::string const& directory, std::map<std::string, std::string> const& environment, std::string const& input, limits_t const& limits);

		~command_runner_t ();
		run_result_t wait ();
		void cancel ();

	private:
		command_runner_t () = default;
		static void drain (std::shared_ptr<command_runner_t> const& runner, int fd, std::string command_runner_t::* dst, size_t cap, run_result_t::status_t overflowReason);
		void terminate_with_reason (run_result_t::status_t reason);
		void sweep_group ();          // _mutex held; the leader exited with no kill pending
		void schedule_escalation ();
		void escalate_to_kill ();
		void reap ();                 // _mutex held; ends the leader’s lifetime, so: group empty, no kill pending
		void unblock_pumps ();
		bool wait_ready (int fd, short events);

		std::mutex _mutex;
		pid_t _pid = -1;              // also the process-group id
		bool _exited = false;         // the leader is a zombie: still ours, not yet reaped
		bool _reaped = false;         // pid released, so nothing may signal the group any more
		bool _signalled = false;      // the group has had its SIGTERM — from a termination or the sweep
		bool _kill_pending = false;   // an escalation owns the leader until its SIGKILL has gone out
		run_result_t::status_t _terminate_reason = run_result_t::status_t::success; // ‘success’ = no termination requested
		std::string _launch_error = NULL_STR;

		limits_t _limits;
		std::string _input;
		std::string _output;          // appended under _mutex by the drains
		std::string _error;
		dispatch_group_t _pump_group = nullptr;
		int _unblock_read = -1;       // self-pipe: closing the write end releases pumps stuck on
		int _unblock_write = -1;      // descriptors a process outside the group still holds open
	};

} /* preview */

#endif /* end of include guard: PREVIEW_COMMAND_RUNNER_H_V8KQ3ZTL */
