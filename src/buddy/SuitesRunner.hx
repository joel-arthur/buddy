package buddy;
import buddy.internal.GenerateMain;
import buddy.reporting.Reporter;
import haxe.CallStack;
import haxe.CallStack.StackItem;
import haxe.Log;
import haxe.PosInfos;
import haxe.rtti.Meta;
import promhx.Deferred;
import promhx.Promise;
import buddy.BuddySuite;

#if utest
import utest.Assert;
import utest.Assertation;
#end

using Lambda;
using buddy.tools.AsyncTools;

#if python
@:pythonImport("sys")
extern class PythonSys {
	public static function setrecursionlimit(i : Int) : Void;
} 
#end

@:keep // Prevent dead code elimination, since SuitesRunner is created dynamically
class SuitesRunner
{
	// Used in Should
	public static var currentTest : Should.SpecAssertion;
	
	public var unrecoverableError : Dynamic = null;
	public var unrecoverableErrorStack : Array<StackItem> = null;
	
	private var allTestsPassed : Bool = false;
	private var buddySuites : Iterable<BuddySuite>;
	private var reporter : Reporter;
	private var runCompleted : Deferred<SuitesRunner>;
	
	private var oldLog : Dynamic -> ?PosInfos -> Void;

	///////////////////////////////////////////////////////////////////////
	
	public static function posInfosToStack(p : Null<PosInfos>) : Array<StackItem> {
		return p == null
			? [StackItem.FilePos(null, "", 0)]
			: [StackItem.FilePos(null, p.fileName, p.lineNumber)];
	}

	public function new(buddySuites : Iterable<BuddySuite>, ?reporter : Reporter) {
		this.buddySuites = buddySuites;
		this.reporter = reporter == null ? new buddy.reporting.ConsoleReporter() : reporter;
		this.oldLog = Log.trace;
	}
	
	public function run() : Promise<SuitesRunner> {
		#if python
		PythonSys.setrecursionlimit(10000);
		#end

		runCompleted = new Deferred<SuitesRunner>();
		var runCompletedPromise = runCompleted.promise();

		runDescribes(function(err) {
			if (err != null) haveUnrecoverableError(err);
			else startRun();
		});
		
		return runCompletedPromise;
	}	

	private function runDescribes(cb : Dynamic -> Void) : Void {
		// Process the queue of describe calls
		forEachSeries(buddySuites, function(suite, cb) {
			var queue = suite.describeQueue;
			function processQueue() {
				try {
					if (queue.empty()) return cb(null);
					
					var current = queue.pop();
					
					// Set current suite, that will collect all describe/it/after/before calls.
					suite.currentSuite = current.suite;
				
					switch current.spec {
						case Async(f): f(processQueue);
						case Sync(f): f(); processQueue();
					}
				} catch (e : Dynamic) {
					cb(e);
				}
			}
			processQueue(); // Neko couldn't do self-calls
		}, function(err) {
			if (err != null) return cb(err);
			
			// If includes exists, start pruning the Suite tree.
			if (Reflect.hasField(Meta.getType(BuddySuite), "includeMode")) startIncludeMode();
			cb(null);
		});
	}
	
	public function failed() return !allTestsPassed;
	public function statusCode() return failed() ? 1 : 0;

	/////////////////////////////////////////////////////////////////////////////

	private function startRun() : Void {
		reporter.start().then(function(go) {
			if (!go) {
				reporter.done([], false).then(function(_) runCompleted.resolve(this));
				return;
			}
			
			var beforeEachStack = [[]];
			var afterEachStack = [[]];
			
			mapSeries(buddySuites, function(buddySuite, done) { 
				mapTestSuite(
					buddySuite, 
					buddySuite.suite, 
					beforeEachStack, 
					afterEachStack, 
				function(err, suite) {
					if (err != null) suiteError(suite, err);
					done(null, suite);
				});
			}, function(err, suites) {
				if (err != null) haveUnrecoverableError(err);
				else {
					allTestsPassed = !suites.exists(function(suite) return !suite.passed());
					reporter.done(suites, allTestsPassed).then(function(_) runCompleted.resolve(this));
				}
			});
		});
	}

	private function startIncludeMode() {
		// Filter out all tests not marked with @include
		function traverse(suite : TestSuite) : Bool {
			suite.specs = suite.specs.filter(function(spec) {
				switch spec {
					case Describe(suite, included):
						if (included) return true;
						else return traverse(suite);
					case It(desc, _, included):
						return included;
				}
			});
			return suite.specs.length > 0;
		}
		
		buddySuites = buddySuites.filter(function(buddySuite) {
			var suiteMeta = Meta.getType(Type.getClass(buddySuite));
			if (Reflect.hasField(suiteMeta, "include")) return true;
			
			return traverse(buddySuite.suite);
		});
	}
	
	// Errors outside it()
	private function suiteError(suite : Suite, err : Dynamic) {
		suite.error = err;
		suite.stack = CallStack.exceptionStack();
	}
	
	private function mapTestSuite(
		buddySuite : BuddySuite, 
		testSuite : TestSuite, 
		beforeEachStack : Array<Array<TestFunc>>,
		afterEachStack : Array<Array<TestFunc>>,
		done : Dynamic -> Suite -> Void
	) : Void {
		var currentSuite = buddy.tests.SelfTest.lastSuite = new Suite(testSuite.description);
		
		beforeEachStack.push(testSuite.beforeEach.array());
		afterEachStack.unshift(testSuite.afterEach.array());

		// === Run beforeAll
		forEachSeries(testSuite.beforeAll, runTestFunc, function(err) {
			if (err != null) return done(err, currentSuite);
			// === Map TestSpec -> Step
			mapSeries(testSuite.specs, function(testSpec : TestSpec, cb : Dynamic -> Step -> Void) {
				mapTestSpec(buddySuite, testSuite, beforeEachStack, afterEachStack, testSpec, cb);
			}, function(err : Dynamic, testSteps : Array<Step>) {
				if (err != null) return done(err, currentSuite);
				// === Run afterAll
				forEachSeries(testSuite.afterAll, runTestFunc, function(err) {
					if (err != null) return done(err, currentSuite);
					currentSuite.steps = testSteps;
					beforeEachStack.pop();
					afterEachStack.shift();

					done(null, currentSuite);
				});
			});
		});
	}

	private function runTestFunc(func : TestFunc, done : Dynamic -> Void) {
		try {
			switch func {
				case Async(f): f(function() done(null));
				case Sync(f): f(); done(null);
			}
		} catch (e : Dynamic) {
			done(e);
		}
	}
	
	private function flatten<T>(arr : Array<Array<T>>) : Array<T> {
		return [for(a in arr) for(b in a) b];
	}

	private	function mapTestSpec(
		buddySuite : BuddySuite, 
		testSuite : TestSuite, 
		beforeEachStack : Array<Array<TestFunc>>,
		afterEachStack : Array<Array<TestFunc>>,
		testSpec : TestSpec,
		done : Dynamic -> Step -> Void
	) : Void {
		var hasCompleted = false;
		var oldFail : ?Dynamic -> ?PosInfos -> Void = null;
		
		oldFail = buddySuite.fail = function(err : Dynamic = "Exception", ?p : PosInfos) {
			// Test if it still references the same suite.
			if (!hasCompleted && oldFail == buddySuite.fail) {
				done(err, null);
			}
		}
		var oldPending = buddySuite.pending = function(?message : String, ?p : PosInfos) {
			done("Cannot call pending here.", null);
		}

		switch testSpec {
			case Describe(testSuite, _): 
				// === Map TestSuite -> Suite
				mapTestSuite(buddySuite, testSuite, beforeEachStack, afterEachStack, function(err : Dynamic, newSuite : Suite) {
					if (err != null) done(err, null);
					else done(null, TSuite(newSuite));
				});
				
			case It(desc, test, _):
				// Assign top-level spec var here, so it can be used in reporting.
				var spec = buddy.tests.SelfTest.lastSpec = new Spec(desc);
				
				// Log traces for each Spec, so they can be outputted in the reporter
				if(!BuddySuite.useDefaultTrace) Log.trace = function(v, ?pos : PosInfos) {
					if(pos == null) spec.traces.push(Std.string(v));
					else spec.traces.push(pos.fileName + ":" + pos.lineNumber + ": " + v);
				};

				// Called when, for any reason, the Spec is completed.
				function specCompleted(status : SpecStatus, error : Dynamic, stack : Array<StackItem>) : Void {
					if (hasCompleted) return;
					hasCompleted = true;
					
					spec.status = status;
					spec.error = error;
					spec.stack = stack;
					
					// Restore Log and set Suites fail function to null
					if(!BuddySuite.useDefaultTrace) Log.trace = oldLog;
					buddySuite.fail = oldFail;
					buddySuite.pending = oldPending;

					// === Run afterEach
					forEachSeries(flatten(afterEachStack), runTestFunc, function(err : Dynamic) {
						if (err != null) done(err, null);
						else reporter.progress(spec).then(function(_) done(null, TSpec(spec)));
					});
				}

				// Test if spec is Pending (has only description)
				if (test == null) {
					specCompleted(Pending, null, null);
					return; // C# and Java cannot return specCompleted directly.
				}

				// Create a test function that will be used in Should
				// note that multiple successfull tests doesn't mean the Spec is completed.
				SuitesRunner.currentTest = function(testStatus : Bool, error : Dynamic, stack : Array<StackItem>) {
					if (hasCompleted || testStatus == true) return;								
					specCompleted(Failed, error, stack);
				}
				
				// Set up utest if available
				#if utest
				Assert.results = new List<Assertation>();

				function checkUtestResults() {
					for (a in Assert.results) switch a {
						case Success(_):										
						case Warning(_):
						case Failure(e, pos):
							var stack = posInfosToStack(pos);
							specCompleted(Failed, e, stack);
							break;
						case Error(e, stack), SetupError(e, stack), TeardownError(e, stack), AsyncError(e, stack):
							specCompleted(Failed, e, stack);
							break;
						case TimeoutError(e, stack):
							specCompleted(Failed, e, stack);
							break;
					}
				}
				#end
				
				#if (!php && !macro)
				// Set up timeout for the current spec
				var timeout = buddySuite.timeoutMs;
				if(timeout > 0) {
					AsyncTools.wait(timeout)
						.catchError(function(e : Dynamic) { 
							specCompleted(Failed, e, CallStack.exceptionStack());
						})
						.then(function(_) specCompleted(Failed, 'Timeout after $timeout ms', null));
				}
				#end
				
				// Set up fail and pending function
				buddySuite.fail = function(err : Dynamic = "Manually", ?p : PosInfos) {
					specCompleted(Failed, err, posInfosToStack(p));
				}

				buddySuite.pending = function(?message : String, ?p : PosInfos) {
					specCompleted(Pending, null, posInfosToStack(p));
				}

				// === Run beforeEach
				forEachSeries(flatten(beforeEachStack), runTestFunc, function(err) {
					if (err != null) return done(err, null);

					// Run the test function, synchronous exceptions will be reported in 'err'.
					runTestFunc(test, function(err) {
						#if utest
						checkUtestResults();
						#end
						if (err != null) specCompleted(Failed, err, CallStack.exceptionStack());
						else specCompleted(Passed, null, null);						
					});
				});
		}
	}	

	public function haveUnrecoverableError(err) {
		unrecoverableError = err;
		unrecoverableErrorStack = CallStack.exceptionStack();
		runCompleted.resolve(this);
	}
	
	private function mapSeries<T, T2, Err>(
		iterable : Iterable<T>, 
		cb : T -> (Null<Err> -> Null<T2> -> Void) -> Void, 
		done : Null<Err> -> Null<Array<T2>> -> Void) 
	{
		var iterator = iterable.iterator();
		var output = [];
		
		function next() {
			if (!iterator.hasNext()) done(null, output);
			else cb(iterator.next(), function(err : Err, mapped : T2) { 
				if (err == null) {
					output.push(mapped); 
					next();
				}
				else done(err, output);
			});
		}
		next(); // Neko couldn't do self-calls
	}

	private function forEachSeries<T, Err>(
		iterable : Iterable<T>, 
		cb : T -> (Null<Err> -> Void) -> Void, 
		done : Null<Err> -> Void) 
	{
		var iterator = iterable.iterator();
		
		function next() {
			if (!iterator.hasNext()) done(null);
			else cb(iterator.next(), function(err : Err) err == null ? next() : done(err));
		}		
		next(); // Neko couldn't do self-calls
	}	
}
