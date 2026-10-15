<cfscript>
/*
 * Rough cost check for the fix. The fix changes every map ColdFusion builds with the two default
 * CaseInsensitiveMap constructors (component and function metadata, tag attribute collections and
 * other engine-internal maps), not only metadata. This page times a few everyday operations,
 * single-threaded, so the stock and fixed servers can be compared. Run it a few times and use
 * the later runs: the first ones include compilation and JIT warm-up.
 */
param name="url.n" default="20000";
n = max( 1000, min( 1000000, int( val( url.n ) ) ) );
results = [:];

t = getTickCount();
for ( i = 1; i <= n; i++ ) {
	p = new model.Person();
	p.setFirstName( "Ada" ); p.setLastName( "Lovelace" );
	x = p.fullName();
}
results[ "create component + accessors" ] = getTickCount() - t;

t = getTickCount();
for ( i = 1; i <= n; i++ ) {
	md = getMetadata( p );
	x = md.properties[ 1 ].name;
}
results[ "getMetadata + read" ] = getTickCount() - t;

t = getTickCount();
for ( i = 1; i <= n; i++ ) {
	savecontent variable="x" { writeOutput( i ); }
	param name="local.unused#i mod 10#" default="";
}
results[ "tag calls (savecontent, param)" ] = getTickCount() - t;

t = getTickCount();
for ( i = 1; i <= n; i++ ) {
	s = { "a" : 1, "b" : 2, "c" : 3 };
	s.d = i;
	x = duplicate( s );
	x = structKeyList( x );
}
results[ "struct build + duplicate" ] = getTickCount() - t;

t = getTickCount();
for ( i = 1; i <= n / 10; i++ ) {
	x = serializeJSON( p );
}
results[ "serializeJSON(component) x n/10" ] = getTickCount() - t;

cfcontent( type = "text/plain", reset = true );
writeOutput( "server: #server.coldfusion.productName# #server.coldfusion.productVersion#, n=#n#" & chr( 10 ) );
for ( k in results ) writeOutput( "#lJustify( k, 34 )# #results[ k ]# ms" & chr( 10 ) );
</cfscript>
