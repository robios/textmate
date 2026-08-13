#include "../src/preview_command_runner.h"
#include <test/jail.h>
#include <text/format.h>

using preview::command_runner_t;
using status_t = preview::run_result_t::status_t;

static std::map<std::string, std::string> const kEnvironment = { { "PATH", "/usr/bin:/bin" } };

static preview::run_result_t run (std::string const& command, std::string const& input = "", command_runner_t::limits_t const& limits = command_runner_t::limits_t(), std::string const& directory = "/tmp")
{
	return command_runner_t::launch(command, directory, kEnvironment, input, limits)->wait();
}

void test_success_fragment ()
{
	auto result = run("printf '<pre data-sourcepos=\"1:1-1:1\">hi</pre>'");
	OAK_ASSERT(result.status == status_t::success);
	OAK_ASSERT_EQ(result.html, "<pre data-sourcepos=\"1:1-1:1\">hi</pre>");
}

void test_stdin_round_trip ()
{
	// 300 KB through ‘cat’ exceeds the 64 KB pipe buffer several times over:
	// this deadlocks unless stdin is pumped while stdout is drained.
	std::string const input(300 * 1024, 'a');
	auto result = run("cat", input);
	OAK_ASSERT(result.status == status_t::success);
	OAK_ASSERT_EQ(result.html.size(), input.size());
	OAK_ASSERT(result.html == input);
}

void test_working_directory ()
{
	auto result = run("pwd", "", command_runner_t::limits_t(), "/usr");
	OAK_ASSERT(result.status == status_t::success);
	OAK_ASSERT_EQ(result.html, "/usr\n");
}

void test_environment_passing ()
{
	auto runner = command_runner_t::launch("printf '%s' \"$TM_PREVIEW\"", "/tmp", { { "TM_PREVIEW", "1" } }, "", command_runner_t::limits_t());
	auto result = runner->wait();
	OAK_ASSERT(result.status == status_t::success);
	OAK_ASSERT_EQ(result.html, "1");
}

void test_nonzero_exit ()
{
	auto result = run("echo boom >&2; exit 3");
	OAK_ASSERT(result.status == status_t::nonzero_exit);
	OAK_ASSERT_EQ(result.exit_code, 3);
	OAK_ASSERT_NE(result.diagnostic.find("status 3"), std::string::npos);
	OAK_ASSERT_NE(result.diagnostic.find("boom"), std::string::npos);
}

void test_launch_failure ()
{
	auto result = run("true", "", command_runner_t::limits_t(), "/nonexistent-preview-dir");
	OAK_ASSERT(result.status == status_t::launch_failed);
	OAK_ASSERT_NE(result.diagnostic.find("Failed to launch"), std::string::npos);
}

void test_invalid_utf8_output ()
{
	auto result = run("printf '\\xc3\\x28'");
	OAK_ASSERT(result.status == status_t::invalid_output);
}

void test_timeout ()
{
	command_runner_t::limits_t limits;
	limits.timeout    = 0.3;
	limits.kill_grace = 0.1;

	auto const start = std::chrono::steady_clock::now();
	auto result = run("sleep 30", "", limits);
	auto const elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();

	OAK_ASSERT(result.status == status_t::timeout);
	OAK_ASSERT_NE(result.diagnostic.find("timed out"), std::string::npos);
	OAK_ASSERT_LT(elapsed, 10.0);
}

void test_cancel ()
{
	command_runner_t::limits_t limits;
	limits.kill_grace = 0.1;

	auto const start = std::chrono::steady_clock::now();
	auto runner = command_runner_t::launch("sleep 30", "/tmp", kEnvironment, "", limits);
	usleep(100'000);
	runner->cancel();
	auto result = runner->wait();
	auto const elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();

	OAK_ASSERT(result.status == status_t::cancelled);
	OAK_ASSERT_EQ(result.diagnostic, "");
	OAK_ASSERT_LT(elapsed, 10.0);
}

void test_output_overflow ()
{
	command_runner_t::limits_t limits;
	limits.max_output = 50'000;
	limits.kill_grace = 0.1;

	auto result = run("yes overflow", "", limits);
	OAK_ASSERT(result.status == status_t::output_overflow);
	OAK_ASSERT_NE(result.diagnostic.find("more than"), std::string::npos);
}

void test_stderr_overflow ()
{
	command_runner_t::limits_t limits;
	limits.max_error  = 50'000;
	limits.kill_grace = 0.1;

	auto result = run("yes overflow 1>&2", "", limits);
	OAK_ASSERT(result.status == status_t::stderr_overflow);
}

void test_stdin_ignored_by_converter ()
{
	// A converter that never reads stdin must not wedge the writer: the input
	// exceeds the pipe buffer, so the writer unblocks via EPIPE when the
	// process exits.
	std::string const input(300 * 1024, 'b');
	auto result = run("printf ok", input);
	OAK_ASSERT(result.status == status_t::success);
	OAK_ASSERT_EQ(result.html, "ok");
}

// The pid a fixture wrote to `pidFile`, waited for; the trailing newline is
// what says the shell finished writing it.
static pid_t wait_for_child_pid (std::string const& pidFile)
{
	for(size_t i = 0; i < 200; ++i)
	{
		std::string const content = path::content(pidFile);
		if(content != NULL_STR && !content.empty() && content.back() == '\n')
			return atoi(content.c_str());
		usleep(25'000);
	}
	return -1;
}

// Whether the process is gone, waiting up to five seconds for it.
static bool wait_for_death (pid_t pid)
{
	for(size_t i = 0; i < 200; ++i)
	{
		if(kill(pid, 0) == -1 && errno == ESRCH)
			return true;
		usleep(25'000);
	}
	return false;
}

void test_signal_state ()
{
	// The app ignores SIGTERM and blocks it on the dispatch threads renders
	// run from; a converter that inherited either could not be terminated at
	// all, and one that inherited an ignored SIGPIPE would keep writing into
	// a pipeline whose reader is gone.
	auto result = run("kill -TERM $$; printf 'still here'");
	OAK_ASSERT(result.status == status_t::abnormal_exit);
	OAK_ASSERT_EQ(result.html, "");
	OAK_ASSERT_NE(result.diagnostic.find(text::format("signal %d", SIGTERM)), std::string::npos);
}

void test_process_group_kill ()
{
	test::jail_t jail;
	std::string const pidFile = jail.path("pid");

	command_runner_t::limits_t limits;
	limits.kill_grace = 0.1;

	// The background sleep is exactly the pipeline child a plain kill of the
	// shell would orphan; group termination must reach it too.
	auto runner = command_runner_t::launch("sleep 30 & echo $! > '" + pidFile + "'; wait", "/tmp", kEnvironment, "", limits);

	pid_t const childPid = wait_for_child_pid(pidFile);
	OAK_ASSERT(childPid > 0);

	runner->cancel();
	auto result = runner->wait();
	OAK_ASSERT(result.status == status_t::cancelled);

	OAK_ASSERT(wait_for_death(childPid));
}

// ‘exec’ after ignoring SIGTERM leaves a sleep only SIGKILL can stop: the
// dispositions posix_spawn resets are the leader’s, and SIG_IGN survives an
// exec. Both fixtures below use it to keep the process group alive past the
// SIGTERM — which is the case where reaping the leader says nothing at all
// about the group.
static std::string const kSigtermImmuneChild = "{ trap '' TERM; exec sleep 30; } &";

void test_kill_escalation_outlives_the_leader ()
{
	test::jail_t jail;
	std::string const pidFile = jail.path("pid");

	command_runner_t::limits_t limits;
	limits.kill_grace = 0.1;

	// The shell dies of the SIGTERM and is reaped while the child ignores it,
	// so the escalation still owes the group a SIGKILL — which it can only
	// send while the leader’s pid, and with it the group id, is still ours.
	auto runner = command_runner_t::launch(kSigtermImmuneChild + " echo $! > '" + pidFile + "'; wait", "/tmp", kEnvironment, "", limits);

	pid_t const childPid = wait_for_child_pid(pidFile);
	OAK_ASSERT(childPid > 0);

	// Cancelling from another thread is what the pane does, and it is what
	// puts the leader’s death inside the grace period.
	std::thread canceller([&runner]{ usleep(100'000); runner->cancel(); });
	auto result = runner->wait();
	canceller.join();
	OAK_ASSERT(result.status == status_t::cancelled);

	OAK_ASSERT(wait_for_death(childPid));
}

void test_kill_reaches_child_of_exited_shell ()
{
	test::jail_t jail;
	std::string const pidFile = jail.path("pid");

	command_runner_t::limits_t limits;
	limits.kill_grace = 0.1;

	// Same group, but the shell exits normally and at once — so the leader is
	// already a zombie when the cancellation arrives, and the only thing that
	// keeps the group killable is that nobody has reaped it.
	auto runner = command_runner_t::launch(kSigtermImmuneChild + " echo $! > '" + pidFile + "'", "/tmp", kEnvironment, "", limits);

	pid_t const childPid = wait_for_child_pid(pidFile);
	OAK_ASSERT(childPid > 0);

	runner->cancel();
	auto result = runner->wait();
	OAK_ASSERT(result.status == status_t::cancelled);

	OAK_ASSERT(wait_for_death(childPid));
}

void test_cancel_after_the_leader_exited_normally ()
{
	test::jail_t jail;
	std::string const pidFile = jail.path("pid");

	command_runner_t::limits_t limits;
	limits.kill_grace = 0.5; // long enough that the cancellation below lands inside it

	// The shell exits normally and its child keeps the stdout and stderr it
	// inherited, so wait() is still there — parked on the pumps — when the
	// pane closes. Nothing about that ordering may leave the group signalless.
	auto runner = command_runner_t::launch(kSigtermImmuneChild + " echo $! > '" + pidFile + "'", "/tmp", kEnvironment, "", limits);

	std::thread waiter([&runner]{ runner->wait(); });

	pid_t const childPid = wait_for_child_pid(pidFile);
	OAK_ASSERT(childPid > 0);

	runner->cancel();
	waiter.join();

	OAK_ASSERT(wait_for_death(childPid));
}

void test_successful_run_sweeps_its_group ()
{
	test::jail_t jail;
	std::string const pidFile = jail.path("pid");

	command_runner_t::limits_t limits;
	limits.kill_grace = 0.1;

	pid_t childPid = -1;
	{
		// The fragment arrives, the run succeeds, and the caller lets go of the
		// runner at once — the way the pane does. The background job the
		// converter forgot has redirected its stdio, so nothing else is left to
		// notice it: this is the run’s own last chance to clear the group.
		auto runner = command_runner_t::launch("{ trap '' TERM; exec sleep 30; } >/dev/null 2>&1 & echo $! > '" + pidFile + "'; printf '<p>done</p>'", "/tmp", kEnvironment, "", limits);
		auto result = runner->wait();
		OAK_ASSERT(result.status == status_t::success);
		OAK_ASSERT_EQ(result.html, "<p>done</p>");

		childPid = wait_for_child_pid(pidFile);
		OAK_ASSERT(childPid > 0);
	}

	OAK_ASSERT(wait_for_death(childPid));
}
