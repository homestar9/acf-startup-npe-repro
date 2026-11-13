<cfscript>
// Which jar each class was loaded from. With our (withdrawn) fix installed, CaseInsensitiveMap
// comes from hf<version>00-00001-casemap-fix.jar.
cfcontent( type = "text/plain", reset = true );
writeOutput( "server: #server.coldfusion.productName# #server.coldfusion.productVersion#" & chr( 10 ) );
writeOutput( "java:   #createObject( 'java', 'java.lang.System' ).getProperty( 'java.version' )#" & chr( 10 ) & chr( 10 ) );
for ( cls in [ "coldfusion.util.CaseInsensitiveMap", "coldfusion.runtime.AttributeCollection", "coldfusion.runtime.ObjectDuplicator" ] ) {
	loc = createObject( "java", cls ).getClass().getProtectionDomain().getCodeSource().getLocation().toString();
	writeOutput( "#cls##chr( 10 )#    #listLast( loc, '/' )##chr( 10 )#" );
}
backing = createObject( "java", "coldfusion.runtime.AttributeCollection" ).init();
field = backing.getClass().getSuperclass().getDeclaredField( "map" );
field.setAccessible( true );
writeOutput( chr( 10 ) & "component metadata is backed by: #field.get( backing ).getClass().getName()#" & chr( 10 ) );
// Checked by jar name: Adobe's own fix also puts metadata on the concurrent map.
cimJar = createObject( "java", "coldfusion.util.CaseInsensitiveMap" ).getClass().getProtectionDomain().getCodeSource().getLocation().toString();
writeOutput( "our fix installed: #findNoCase( 'casemap-fix', listLast( cimJar, '/' ) ) ? 'yes' : 'no'#" & chr( 10 ) );
</cfscript>
