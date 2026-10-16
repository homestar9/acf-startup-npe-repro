component {

	this.name = "acf-startup-npe-repro";
	this.applicationTimeout = createTimeSpan( 0, 1, 0, 0 );
	this.sessionManagement = false;

	// index.cfm writes its components into this folder's gen/, wherever the folder is copied.
	this.mappings[ "/gen" ] = getDirectoryFromPath( getCurrentTemplatePath() ) & "gen";

}
