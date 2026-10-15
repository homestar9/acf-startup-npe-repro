component accessors="true" {

	property name="firstName" type="string";
	property name="lastName"  type="string";
	property name="email"     type="string";
	property name="age"       type="numeric";

	function init() {
		return this;
	}

	function fullName() {
		return getFirstName() & " " & getLastName();
	}

}
