#include "preview_command_runner.h"
#include <io/pipe.h>
#include <text/format.h>
#include <text/utf8.h>
#include <oak/datatypes.h>
#include <poll.h>

namespace preview
{
	// Script errors are overwhelmingly ASCII; when stderr is not valid UTF-8 we
	// keep the ASCII bytes readable instead of dropping the diagnostic wholesale.
	static std::string sanitized (std::string const& str)
	{
		if(utf8::is_valid(str.begin(), str.end()))
			return str;

		std::string res = str;
		for(char& ch : res)
		{
			if(ch & 0x80)
				ch = '?';
		}
		return res;
	}

	static std::string format_cap (char const* stream, size_t cap)
	{
		if(cap >= (1 << 20) && (cap & ((1 << 20)-1)) == 0)
			return text::format("Preview command produced more than %zu MB of %s.", cap >> 20, stream);
		return text::format("Preview command produced more than %zu bytes of %s.", cap, stream);
	}

	std::shared_ptr<command_runner_t> command_runner_t::launch (std::string const& command, std::string const& directory, std::map<std::string, std::string> const& environment, std::string const& input, limits_t const& limits)
	{
		std::shared_ptr<command_runner_t> runner(new command_runner_t);
		runner->_limits = limits;
		runner->_input  = input;

		int stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite, unblockRead, unblockWrite;
		std::tie(stdinRead, stdinWrite)     = io::create_pipe();
		std::tie(stdoutRead, stdoutWrite)   = io::create_pipe();
		std::tie(stderrRead, stderrWrite)   = io::create_pipe();
		std::tie(unblockRead, unblockWrite) = io::create_pipe();
		if(stdinRead == -1 || stdoutRead == -1 || stderrRead == -1 || unblockRead == -1)
		{
			for(int fd : { stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite, unblockRead, unblockWrite })
			{
				if(fd != -1)
					close(fd);
			}
			runner->_launch_error = "Failed to launch preview command: could not create pipes.";
			return runner;
		}

		// The app-side ends belong to the pump threads, which is why nobody
		// else can close them: this pipe is how the run tells the pumps to let
		// go instead. Closing its write end wakes all three at once.
		runner->_unblock_read  = unblockRead;
		runner->_unblock_write = unblockWrite;

		// Our writer must see EPIPE, not die of SIGPIPE, when the converter
		// exits (or is killed) before reading all of its stdin, and must not
		// park in write() when a surviving child keeps the pipe full.
		fcntl(stdinWrite, F_SETNOSIGPIPE, 1);
		fcntl(stdinWrite, F_SETFL, O_NONBLOCK);

		int rc = -1;
		posix_spawn_file_actions_t fileActions;
		posix_spawnattr_t attr;
		if(posix_spawn_file_actions_init(&fileActions) == 0)
		{
			if(posix_spawnattr_init(&attr) == 0)
			{
				// A new process group so that termination reaches pipelines and
				// grandchildren, not just the shell — plus the signal state a
				// process started from a terminal would have, without which the
				// SIGTERM could not reach them: the app ignores SIGTERM, SIGINT
				// and SIGPIPE (exec inherits SIG_IGN), and the dispatch thread
				// we spawn from blocks SIGTERM, SIGINT and SIGHUP.
				sigset_t everySignal, noSignal;
				sigfillset(&everySignal);
				sigemptyset(&noSignal);

				if(posix_spawn_file_actions_adddup2(&fileActions, stdinRead, STDIN_FILENO) == 0 && posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO) == 0 && posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO) == 0 && posix_spawn_file_actions_addchdir_np(&fileActions, directory.c_str()) == 0 && posix_spawnattr_setsigdefault(&attr, &everySignal) == 0 && posix_spawnattr_setsigmask(&attr, &noSignal) == 0 && posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETPGROUP) == 0 && posix_spawnattr_setpgroup(&attr, 0) == 0)
				{
					char const* argv[] = { "/bin/sh", "-c", command.c_str(), nullptr };
					rc = posix_spawn(&runner->_pid, argv[0], &fileActions, &attr, (char* const*)argv, oak::c_array(environment));
				}
				posix_spawnattr_destroy(&attr);
			}
			posix_spawn_file_actions_destroy(&fileActions);
		}

		close(stdinRead);
		close(stdoutWrite);
		close(stderrWrite);

		if(rc != 0)
		{
			close(stdinWrite);
			close(stdoutRead);
			close(stderrRead);
			runner->_pid = -1;
			runner->_launch_error = text::format("Failed to launch preview command: %s.", strerror(rc == -1 ? EINVAL : rc));
			return runner;
		}

		runner->_pump_group = dispatch_group_create();
		dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
		std::shared_ptr<command_runner_t> const strongRunner = runner;

		dispatch_group_async(runner->_pump_group, queue, ^{
			size_t written = 0;
			while(written < strongRunner->_input.size() && strongRunner->wait_ready(stdinWrite, POLLOUT))
			{
				ssize_t len = write(stdinWrite, strongRunner->_input.data() + written, std::min<size_t>(strongRunner->_input.size() - written, 65536));
				if(len == -1 && (errno == EINTR || errno == EAGAIN))
					continue;
				if(len <= 0) // EPIPE: the converter stopped reading — its business, not a failure of ours
					break;
				written += len;
			}
			close(stdinWrite);
		});

		dispatch_group_async(runner->_pump_group, queue, ^{
			drain(strongRunner, stdoutRead, &command_runner_t::_output, strongRunner->_limits.max_output, run_result_t::status_t::output_overflow);
		});

		dispatch_group_async(runner->_pump_group, queue, ^{
			drain(strongRunner, stderrRead, &command_runner_t::_error, strongRunner->_limits.max_error, run_result_t::status_t::stderr_overflow);
		});

		// The hard timeout lives on its own timer so it fires no matter which
		// queue is blocked waiting for the process.
		std::weak_ptr<command_runner_t> weakRunner = runner;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limits.timeout * NSEC_PER_SEC)), queue, ^{
			if(std::shared_ptr<command_runner_t> strong = weakRunner.lock())
				strong->terminate_with_reason(run_result_t::status_t::timeout);
		});

		return runner;
	}

	command_runner_t::~command_runner_t ()
	{
		if(_pump_group)
			dispatch_release(_pump_group);

		// The pumps hold a reference to us for as long as they run, so by now
		// both ends of the unblock pipe are ours alone.
		for(int fd : { _unblock_read, _unblock_write })
		{
			if(fd != -1)
				close(fd);
		}
	}

	// Blocks until fd is ready, or until the run gives up on the pumps —
	// which is the only way a pump can be released from a descriptor that a
	// process outside our group inherited and keeps open. Pending data (or
	// EOF) wins over the release, so giving up never truncates output that
	// has already arrived.
	bool command_runner_t::wait_ready (int fd, short events)
	{
		while(true)
		{
			struct pollfd fds[2] = { { fd, events, 0 }, { _unblock_read, POLLIN, 0 } };
			if(poll(fds, 2, -1) == -1)
			{
				if(errno == EINTR)
					continue;
				return false;
			}
			if(fds[0].revents) // ready, EOF, or an error for read()/write() to report
				return true;
			if(fds[1].revents)
				return false;
		}
	}

	void command_runner_t::unblock_pumps ()
	{
		int fd = -1;
		{
			std::lock_guard<std::mutex> lock(_mutex);
			std::swap(fd, _unblock_write);
		}
		if(fd != -1)
			close(fd);
	}

	void command_runner_t::drain (std::shared_ptr<command_runner_t> const& runner, int fd, std::string command_runner_t::* dst, size_t cap, run_result_t::status_t overflowReason)
	{
		char buf[65536];
		while(runner->wait_ready(fd, POLLIN))
		{
			ssize_t len = read(fd, buf, sizeof(buf));
			if(len == -1 && errno == EINTR)
				continue;
			if(len <= 0)
				break;

			bool overflow = false;
			{
				std::lock_guard<std::mutex> lock(runner->_mutex);
				std::string& buffer = (*runner).*dst;
				if(buffer.size() + len > cap)
						overflow = true;
				else	buffer.append(buf, len);
			}

			if(overflow)
			{
				runner->terminate_with_reason(overflowReason);
				break;
			}
		}
		close(fd);
	}

	void command_runner_t::cancel ()
	{
		terminate_with_reason(run_result_t::status_t::cancelled);
	}

	void command_runner_t::terminate_with_reason (run_result_t::status_t reason)
	{
		pid_t pid = -1;
		{
			std::lock_guard<std::mutex> lock(_mutex);
			if(_terminate_reason == run_result_t::status_t::success) // first reason wins
				_terminate_reason = reason;
			if(_signalled || _reaped || _pid == -1)
				return;
			_signalled    = true;
			_kill_pending = true;
			pid = _pid;
		}

		killpg(pid, SIGTERM);
		schedule_escalation();
	}

	// The run is over as far as the reader is concerned, but the group need not
	// be: a converter that started a background job leaves it in there, holding
	// descriptors and CPU with nobody left to stop it. So the leader’s exit
	// buys the group the same SIGTERM, grace period and SIGKILL a cancellation
	// would — the pid is given up only once there is nothing left in there to
	// signal. Called with _mutex held, the leader exited and no kill pending.
	void command_runner_t::sweep_group ()
	{
		// A group whose only member is the zombie leader has nothing to
		// signal and says so — as EPERM, which is how macOS reports an empty
		// match to a UNIX03 caller. That is what every well-behaved converter
		// leaves behind, and it must not cost a render a grace period.
		if(killpg(_pid, SIGTERM) == -1)
		{
			reap();
			return;
		}

		_signalled    = true;
		_kill_pending = true;
		schedule_escalation();
	}

	// A strong reference: the escalation is the group’s only remaining kill
	// path, and the pane drops the runner as soon as wait() hands back a
	// result — which the leader’s death is enough for.
	void command_runner_t::schedule_escalation ()
	{
		std::shared_ptr<command_runner_t> const strongThis = shared_from_this();
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_limits.kill_grace * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			strongThis->escalate_to_kill();
		});
	}

	// The SIGKILL the grace period was for, whether a termination or the run’s
	// own sweep started it. The leader having been reaped is what would make
	// this unsafe — its pid is the group id, and a reaped pid can be recycled —
	// so the leader stays a zombie while this is pending, and the reap lands
	// here instead.
	void command_runner_t::escalate_to_kill ()
	{
		{
			std::lock_guard<std::mutex> lock(_mutex);
			if(!_kill_pending)
				return;
			_kill_pending = false;

			killpg(_pid, SIGKILL);
			if(_exited)
				reap();
		}

		// Whatever stayed in the group is gone now, so it has dropped the pipe
		// ends it inherited; anything still holding them left the group and is
		// past our reach.
		unblock_pumps();
	}

	void command_runner_t::reap ()
	{
		pid_t rc;
		do {
			rc = waitpid(_pid, nullptr, 0); // wait() took the status from the siginfo
		} while(rc == -1 && errno == EINTR);
		_reaped = true;
	}

	run_result_t command_runner_t::wait ()
	{
		run_result_t res;

		if(_pid == -1)
		{
			res.status     = run_result_t::status_t::launch_failed;
			res.diagnostic = _launch_error != NULL_STR ? _launch_error : std::string("Failed to launch preview command.");
			return res;
		}

		// Wait for the leader without reaping it: the group is not dead just
		// because its leader is, and its pid is the only handle anyone still
		// has on what may be left in there. The exit status comes from the
		// siginfo, so the reap is pure bookkeeping for whichever path — a
		// pending escalation, or the sweep below — leaves the group empty.
		siginfo_t info;
		int rc;
		do {
			memset(&info, 0, sizeof(info));
			rc = waitid(P_PID, _pid, &info, WEXITED|WNOWAIT);
		} while(rc == -1 && errno == EINTR);

		{
			std::lock_guard<std::mutex> lock(_mutex);
			_exited = true;
			if(!_kill_pending) // otherwise a termination already owns the group, SIGKILL included
				sweep_group();
		}

		// With the group dead the child ends of the pipes are closed and the
		// pumps finish promptly. A converter that daemonized out of the group
		// with a pipe inherited could hold them open — bound the wait, then
		// release the pumps and report with what has been read.
		if(dispatch_group_wait(_pump_group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0)
		{
			unblock_pumps();
			dispatch_group_wait(_pump_group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
		}

		std::lock_guard<std::mutex> lock(_mutex);

		auto withStderr = [this](std::string message) {
			if(!_error.empty())
				message += "\n\n" + sanitized(_error);
			return message;
		};

		if(_terminate_reason != run_result_t::status_t::success)
		{
			res.status = _terminate_reason;
			switch(_terminate_reason)
			{
				case run_result_t::status_t::timeout:         res.diagnostic = withStderr(text::format("Preview command timed out after %.0f seconds.", _limits.timeout)); break;
				case run_result_t::status_t::output_overflow: res.diagnostic = withStderr(format_cap("output", _limits.max_output)); break;
				case run_result_t::status_t::stderr_overflow: res.diagnostic = withStderr(format_cap("stderr", _limits.max_error)); break;
				default: break; // cancellation is silent
			}
		}
		else if(rc == -1 || info.si_code != CLD_EXITED)
		{
			res.status     = run_result_t::status_t::abnormal_exit;
			res.diagnostic = withStderr(rc == 0 ? text::format("Preview command terminated by signal %d.", info.si_status) : std::string("Preview command terminated abnormally."));
		}
		else if(info.si_status != 0)
		{
			res.status     = run_result_t::status_t::nonzero_exit;
			res.exit_code  = info.si_status;
			res.diagnostic = withStderr(text::format("Preview command exited with status %d.", res.exit_code));
		}
		else if(!utf8::is_valid(_output.begin(), _output.end()))
		{
			res.status     = run_result_t::status_t::invalid_output;
			res.diagnostic = withStderr("Preview command output is not valid UTF-8.");
		}
		else
		{
			res.status = run_result_t::status_t::success;
			res.html   = std::move(_output);
		}

		return res;
	}

} /* preview */
