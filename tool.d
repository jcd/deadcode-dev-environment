import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.format;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.string;
import std.typecons;

string dubPath;

void usage()
{
	auto usageTmpl = q"XX
tool <command> [command options...]
Commands
  test      : Run tests (building if necessary) optional filter can be provided
  showDeps  : Show dependencies of repos in the deadcode-* folders
XX";
	write(usageTmpl);
}

void main(string[] args)
{
	dubPath = environment.get("DUB", "./dub");

    if (!exists(dubPath))
        dubPath = "dub"; // Maybe it is in PATH

	switch (args[1])
	{
		case "test":
			test(args);
			break;
		case "showDeps":
			showDeps(args);
			break;
		default:
			writeln("No such command " ~ args[1]);
			usage();
			break;
	}
}

string[] getSubjects(string[] args)
{
	string[] testSubjects;

	if (args.length > 2 && args[2] != "all")
	{
		testSubjects = [ args[2].replace(".","").replace("/","").replace("\\","") ];
	}
	else
	{
		testSubjects = dirEntries(".", SpanMode.shallow)
			.filter!(a => a.isDir)
			.map!(a => std.path.baseName(a.name))
			.array;
	}
	return testSubjects;
}

void test(string[] args, bool showUsage = false)
{
	if (showUsage)
	{
		writeln("tool test");
		writeln("Run all unittest. Takes an optional argument used for filtering output.");
		return;
	}

	auto testSubjects = getSubjects(args);

	string filt = args.length > 3 ? args[3] : "";

	static auto runTestCoverage(string pack, string filt)
	{
		struct Result
		{
			int exitCode;
			string log;
			string result;
			int coverage;
			int maxModuleNameLength;
		}
		Result result;

		string coverageDir = ".coverage/" ~ pack;
		mkdirRecurse(coverageDir);
		chdir(coverageDir);

		// auto cmd = dubPath ~ " -q run --build=unittest -- unittestoutput.txt";
		auto cmd = dubPath ~ " --root=../../" ~ pack ~ " test --coverage ";
		stdout.write(pack, ": ");
		stdout.flush();
		auto res = pipeShell(cmd, Redirect.stdin | Redirect.stderrToStdout | Redirect.stdout);
		string resultPrefix = "Test results: ";
		foreach (line; res.stdout.byLine)
		{
			if (filt.empty || line.startsWith("0x") || !line.find(filt).empty || !line.toLower().find("exception").empty)
			{
				if (line.startsWith(resultPrefix))
					result.result = line.idup[resultPrefix.length..$]; 
				result.log ~= line;
			}
		}
		result.exitCode = wait(res.pid); 
	
		static r = ctRegex!(`.*is (\d+)% covered`);

		auto covFiles = dirEntries(".", SpanMode.shallow)
			.filter!(a => a.isFile)
			.map!(a => std.path.baseName(a.name))
			.filter!(a => a.startsWith("..-..-" ~ pack))
			.map!((string a) { auto m = readText(a).matchFirst(r); return tuple(a[7+pack.length..$-4].replace("-", "."), m.empty ? 0 : m[1].to!int); })
			.array;

		writeln();

		result.maxModuleNameLength = covFiles.fold!((a,b) => max(b[0].length, a))(0);
		covFiles.each!(a => writefln("\t%-*s: %s", result.maxModuleNameLength, a[0], a[1]));

		result.coverage = covFiles.map!(a => a[1]).sum / covFiles.length;

		auto f = File("test-output.txt", "w");
		f.write(result.log);
		f.flush();

		import std.range;
		writeln('\t', repeat('-', result.maxModuleNameLength + 4));
		writefln("\t%-*s: %s", result.maxModuleNameLength, "Average coverage", result.coverage);
		writefln("\t%-*s: %s", result.maxModuleNameLength, "Tests result", result.result);
		writeln();
		chdir("../../");
		return result;
	}

	auto skip = [ "deadcode-extensions" ];

	int count = 0;
	int coverageSum = 0;

	foreach (p; testSubjects)
	{
		if (skip.canFind(p))
		{
			writeln("Skipping ", p, " on request\n");
		}
		else if (exists(p ~ "/dub.json"))
		{
			auto res = runTestCoverage(p, filt);
			count++;
			coverageSum += res.coverage;
			
			if (res.exitCode != 0)
			{
				writeln(res.log);
				break;
			}
		}
	}
	writeln("Total avg. coverage ", coverageSum / count);
}

void showDeps(string[] args, bool showUsage = false)
{
	if (showUsage)
	{
		writeln("tool showDeps");
		writeln("Display deps stated in dub file and actual deps but scanning files.\nTakes an optional argument used for filtering output.");
		return;
	}

	static auto getDubDependencies(string path)
	{
		import std.json;
		auto jsonText = readText(path ~ "/dub.json");
		auto json = parseJSON(jsonText);
	
		static string[] jsonVisit(ref JSONValue val)
		{
			string[] elms;	
			
			if (val.type == JSON_TYPE.OBJECT)
			{
				foreach (k,v; val.object)
				{
					if (k == "dependencies")
					{
						foreach (k2,v2; v.object)
							elms ~= k2;
					}
					else
					{
						elms ~= jsonVisit(v);
					}
				}
			} 
			else if (val.type == JSON_TYPE.ARRAY)
			{
				foreach (k,v; val.array)
				{
					elms ~= jsonVisit(v);
				}
			}
			return elms;
		}

		auto accDeps = jsonVisit(json);

		auto deps = sort(accDeps).uniq.array;

		struct Result
		{
			string[] elms;
			string packageName;
		}
		Result r = { deps, json.object["name"].str };
		return r;
	}

	static string[] getModuleDependencies(string path, string packageName)
	{
		auto files = dirEntries(path, "*.d", SpanMode.depth)
			.filter!(a => a.isFile);
		
		static r = ctRegex!(`import\s([\w\.]+)`, "gim");

		string[] result;

		foreach (e; files)
		{
			auto matches = readText(e.name).matchAll(r);
			foreach (m; matches)
			{
				result ~= m[1];
			}
		}
		return sort(result).filter!(a => !a.startsWith(packageName) && !a.startsWith("std.") && !a.startsWith("core.")).uniq.array;
	}

	auto testSubjects = getSubjects(args);

	auto skip = [ "deadcode-extensions", "deadcode-editor" ];

	foreach (p; testSubjects)
	{
		if (skip.canFind(p))
		{
			writeln("Skipping ", p, " on request\n");
		}
		else if (exists(p ~ "/dub.json"))
		{
			auto dubDeps = getDubDependencies(p);
			stdout.write("Dependencies for ", dubDeps.packageName, "\n");
			stdout.flush();
			auto scanDeps = getModuleDependencies(p, dubDeps.packageName.replace("-",".")); 

			writeln("\tDub specified: ", dubDeps.elms);
			writeln("\tScanned      : ", scanDeps);
			writeln();
		}
	}
}

