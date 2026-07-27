#include <markdown/markdown_render.h>

static double const AppVersion = 1.0;

static void version ()
{
	fprintf(stdout, "%1$s %2$.1f (" __DATE__ ")\n", getprogname(), AppVersion);
}

static void usage (FILE* io = stdout)
{
	fprintf(io,
		"%1$s %2$.1f (" __DATE__ ")\n"
		"Usage: %1$s [-hv] [file ...]\n"
		"Render Markdown as an HTML fragment (GitHub-flavored, same engine and\n"
		"settings as TextMate\xE2\x80\x99s live preview). Reads standard input when no\n"
		"file arguments are given.\n"
		"Options:\n"
		" -h, --help                Show this information.\n"
		" -v, --version             Print version information.\n"
		"\n", getprogname(), AppVersion
	);
}

static std::string slurp (FILE* io)
{
	std::string res;
	char buf[8192];
	size_t len;
	while((len = fread(buf, 1, sizeof(buf), io)) > 0)
		res.append(buf, len);
	return res;
}

int main (int argc, char* const* argv)
{
	extern int optind;

	static struct option const longopts[] = {
		{ "help",             no_argument,         0,      'h'   },
		{ "version",          no_argument,         0,      'v'   },
		{ 0,                  0,                   0,      0     }
	};

	int ch;
	while((ch = getopt_long(argc, argv, "hv", longopts, nullptr)) != -1)
	{
		switch(ch)
		{
			case 'h': usage();             return EX_OK;
			case 'v': version();           return EX_OK;
			default:  usage(stderr);       return EX_USAGE;
		}
	}

	argc -= optind;
	argv += optind;

	std::string input;
	if(argc == 0)
	{
		input = slurp(stdin);
	}
	else
	{
		for(int i = 0; i < argc; ++i)
		{
			FILE* io = fopen(argv[i], "r");
			if(!io)
			{
				fprintf(stderr, "%s: %s: %s\n", getprogname(), argv[i], strerror(errno));
				return EX_NOINPUT;
			}
			input += slurp(io);
			fclose(io);
		}
	}

	std::string const html = markdown::to_html(input, false);
	fwrite(html.data(), 1, html.size(), stdout);
	return EX_OK;
}
