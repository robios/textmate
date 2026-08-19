#ifndef PTY_HELPER_PROTOCOL_H_5C1A7E36
#define PTY_HELPER_PROTOCOL_H_5C1A7E36

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Startup protocol between PTYController and the TextMatePTYHelper trampoline
// it spawns in the shell’s place. Internal to the Terminal framework — the
// helper is an implementation detail of -[PTYController spawn].
//
// Invocation is purely positional, so nothing is parsed by either side:
//
//   argv[0] = "TextMatePTYHelper"
//   argv[1] = requested working directory (falls back to "/" when unusable)
//   argv[2] = absolute path of the target executable
//   argv[3] = target argv[0] (e.g. “-zsh” for a login shell)
//   argv[4…] = target arguments
//
// The helper inherits the pty slave on 0/1/2 and the write end of a status
// pipe on fd 3, which it makes close-on-exec before anything else. The parent
// then reads that pipe to a definitive answer: zero bytes before EOF means the
// target reached execve, one complete pty_helper_error_t means startup failed
// and where. Anything else is a protocol failure.

enum
{
	pty_helper_status_fd = 3,
	pty_helper_magic     = 0x544D5054, // 'TMPT'
	pty_helper_version   = 1,
};

// The step the helper was performing when it gave up. Entering the requested
// working directory is deliberately absent: falling back to "/" is defined
// behavior, so only a failing fallback is reported.
enum pty_helper_stage_t
{
	pty_helper_stage_invalid_arguments = 1,
	pty_helper_stage_status_fd_setup,
	pty_helper_stage_invalid_standard_streams,
	pty_helper_stage_invalid_session_state,
	pty_helper_stage_acquire_controlling_terminal,
	pty_helper_stage_set_foreground_process_group,
	pty_helper_stage_open_controlling_terminal_alias,
	pty_helper_stage_change_to_fallback_directory,
	pty_helper_stage_exec_target,
};

// Fixed-layout, fixed-width fields only: this crosses an exec boundary.
struct pty_helper_error_t
{
	uint32_t magic;
	uint16_t version;
	uint16_t stage;
	int32_t  error_number;
};

// A payload is a valid failure report only when it is exactly one record of a
// version we understand, carrying a stage that version defines; a short,
// oversized, or foreign payload means the writer was not the helper we spawned
// (or died mid-write) and must not be mistaken for a diagnosis. A stage this
// version never wrote is the same situation, not a helper error to report.
static inline bool pty_helper_error_decode (void const* bytes, size_t length, struct pty_helper_error_t* out)
{
	struct pty_helper_error_t record;
	if(length != sizeof(record))
		return false;
	memcpy(&record, bytes, sizeof(record));
	if(record.magic != pty_helper_magic || record.version != pty_helper_version)
		return false;
	if(record.stage < pty_helper_stage_invalid_arguments || record.stage > pty_helper_stage_exec_target)
		return false;
	if(out)
		*out = record;
	return true;
}

static inline char const* pty_helper_stage_name (uint16_t stage)
{
	switch(stage)
	{
		case pty_helper_stage_invalid_arguments:               return "invalid arguments";
		case pty_helper_stage_status_fd_setup:                 return "status fd setup";
		case pty_helper_stage_invalid_standard_streams:        return "invalid standard streams";
		case pty_helper_stage_invalid_session_state:           return "invalid session state";
		case pty_helper_stage_acquire_controlling_terminal:    return "acquire controlling terminal";
		case pty_helper_stage_set_foreground_process_group:    return "set foreground process group";
		case pty_helper_stage_open_controlling_terminal_alias: return "open /dev/tty";
		case pty_helper_stage_change_to_fallback_directory:    return "change to fallback directory";
		case pty_helper_stage_exec_target:                     return "exec target";
	}
	return "unknown stage";
}

#endif /* end of include guard: PTY_HELPER_PROTOCOL_H_5C1A7E36 */
