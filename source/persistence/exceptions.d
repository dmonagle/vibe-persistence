module persistence.exceptions;

class NoModelForIdException : Exception {
	this(string s) { super(s); }
}

