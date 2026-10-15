<cfscript>
/*
 * Startup crash reproduction: component metadata is a plain java.util.HashMap.
 *
 * getMetadata() returns the engine's own, live metadata structs for a component class; every
 * request gets the same objects. Ordinary CFML structs are backed by a concurrent map, but these
 * (coldfusion.runtime.AttributeCollection -> coldfusion.util.CaseInsensitiveMap(int)) are backed
 * by an unsynchronized java.util.HashMap.
 *
 * Each run writes brand-new components (so their metadata is untouched, as it is right after a
 * restart), then starts N threads at the same instant. For each component (the threads line up
 * again before each one), every thread creates
 * it, takes getMetadata(), fills in default keys on each property struct the way an ORM does on
 * first use (Quick's BaseEntity.paramAttribute), and duplicate()s the metadata.
 *
 * Then one thread checks each component again, one call at a time.
 *
 * Expected:
 *   stock ColdFusion 2023 / 2025 ........ FAIL: NullPointerException in duplicate() and
 *                                          "Element NAME is undefined"; the broken components stay
 *                                          broken for every later request until restart
 *   with the CaseInsensitiveMap fix ..... PASS
 *
 * URL options: threads (10, ColdFusion's default cfthread limit), classes (10), properties (12),
 *   mode = param  - write default keys into the metadata, then duplicate() it (what an ORM does)
 *          write  - only write the keys; no duplicate() during the burst
 *          struct - the same writes into an ordinary CFML struct (control: always passes)
 *   trace  - also print the first error's Java stack trace
 */
param name="url.threads"    default="10";
param name="url.classes"    default="10";
param name="url.properties" default="12";
param name="url.mode"       default="param";
threads    = max( 1, min( 200, int( val( url.threads ) ) ) );
classCount = max( 1, min( 100, int( val( url.classes ) ) ) );
propCount  = max( 1, min( 100, int( val( url.properties ) ) ) );
mode       = listFindNoCase( "param,write,struct", url.mode ) ? lCase( url.mode ) : "param";

// 1. Brand-new component classes for this run, and (for mode=struct) ordinary structs shaped the same way.
runId  = "R" & left( replace( createUUID(), "-", "", "all" ), 16 );
genDir = expandPath( "/gen" );
if ( !directoryExists( genDir ) ) directoryCreate( genDir );
src = [ 'component accessors="true" {' ];
for ( i = 1; i <= propCount; i++ ) src.append( '	property name="field#i#" type="string";' );
src.append( '}' );
cfcPaths = [];
structs  = [];
for ( c = 1; c <= classCount; c++ ) {
	fileWrite( genDir & "/" & runId & "_" & c & ".cfc", arrayToList( src, chr( 10 ) ) );
	cfcPaths.append( "gen." & runId & "_" & c );
	s = { "properties" : [] };
	for ( i = 1; i <= propCount; i++ ) s.properties.append( { "name" : "field#i#", "type" : "string" } );
	structs.append( s );
}

application[ runId ] = {
	"latch"    : createObject( "java", "java.util.concurrent.CountDownLatch" ).init( 1 ),
	"barrier"  : createObject( "java", "java.util.concurrent.CyclicBarrier" ).init( javaCast( "int", threads ) ),
	"seconds"  : createObject( "java", "java.util.concurrent.TimeUnit" ).SECONDS,
	"results"  : createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init(),
	"cfcPaths" : cfcPaths,
	"structs"  : structs
};

// 2. N threads behind one start gate.
names = [];
for ( i = 1; i <= threads; i++ ) {
	tName = runId & "_t" & i;
	names.append( tName );
	thread name="#tName#" runId=runId mode=mode idx=i {
		var ctx = application[ attributes.runId ];
		var res = { "errors" : 0, "messages" : {}, "trace" : "", "barrierBroken" : false };
		ctx.latch.await();
		for ( var c = 1; c <= ctx.cfcPaths.len(); c++ ) {
			// Line every thread up again, so all of them reach each new component together.
			try {
				ctx.barrier.await( javaCast( "long", 20 ), ctx.seconds );
			} catch ( any e ) {
				res.barrierBroken = true;
				break;
			}
			try {
				var obj = createObject( "component", ctx.cfcPaths[ c ] );
				var md  = attributes.mode == "struct" ? ctx.structs[ c ] : getMetadata( obj );
				for ( var prop in md.properties ) {
					param prop.column        = prop.name;
					param prop.persistent    = true;
					param prop.nullValue     = "";
					param prop.convertToNull = true;
					param prop.readOnly      = false;
					param prop.insert        = true;
					param prop.update        = true;
					param prop.exclude       = false;
				}
				if ( attributes.mode != "write" ) {
					duplicate( md );
				}
			} catch ( any e ) {
				res.errors++;
				res.messages[ e.message ] = ( res.messages[ e.message ] ?: 0 ) + 1;
				if ( !len( res.trace ) ) res.trace = e.stackTrace ?: "";
			}
		}
		ctx.results.put( "t" & attributes.idx, res );
	}
}
sleep( 300 );
application[ runId ].latch.countDown();
thread action="join" name="#arrayToList( names )#" timeout="120000";

burstErrors   = 0;
messages      = {};
firstTrace    = "";
barrierBroken = application[ runId ].results.size() != threads;
for ( key in application[ runId ].results ) {
	r = application[ runId ].results[ key ];
	if ( r.barrierBroken ) barrierBroken = true;
	burstErrors += r.errors;
	for ( msg in r.messages ) messages[ msg ] = ( messages[ msg ] ?: 0 ) + r.messages[ msg ];
	if ( !len( firstTrace ) && len( r.trace ) ) firstTrace = r.trace;
}

// 3. Afterwards, one call at a time: which components are still broken?
brokenClasses = 0;
afterSample   = "";
for ( c = 1; c <= classCount; c++ ) {
	try {
		for ( i = 1; i <= 3; i++ ) {
			duplicate( mode == "struct" ? structs[ c ] : getMetadata( createObject( "component", cfcPaths[ c ] ) ) );
		}
	} catch ( any e ) {
		brokenClasses++;
		afterSample = e.message;
	}
}
structDelete( application, runId );

failed = burstErrors > 0 || brokenClasses > 0;
cfcontent( type = "text/plain", reset = true );
writeOutput( "server:        #server.coldfusion.productName# #server.coldfusion.productVersion#" & chr( 10 ) );
writeOutput( "run:           #runId#: #classCount# new components x #propCount# properties, #threads# threads, mode=#mode#" & chr( 10 ) );
writeOutput( "burst errors:  #burstErrors# of #threads * classCount# calls" & chr( 10 ) );
for ( msg in messages ) writeOutput( "   #messages[ msg ]# x #msg#" & chr( 10 ) );
writeOutput( "after burst:   #brokenClasses# of #classCount# components still fail on every call#len( afterSample ) ? ' (' & afterSample & ')' : ''#" & chr( 10 ) );
if ( barrierBroken ) {
	writeOutput( "result:        INVALID: the #threads# threads did not all run at once. ColdFusion runs at most 10 cfthreads at a time by default" & chr( 10 ) );
	writeOutput( "               (Administrator > Server Settings > Request Tuning). Use threads=10 or raise that limit." & chr( 10 ) );
} else {
	writeOutput( "result:        #failed ? 'FAIL' : 'PASS'#" & chr( 10 ) );
}
if ( len( firstTrace ) && structKeyExists( url, "trace" ) ) writeOutput( chr( 10 ) & left( firstTrace, 6000 ) & chr( 10 ) );
</cfscript>
