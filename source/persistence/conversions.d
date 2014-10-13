module persistence.conversions;

import std.datetime;

// Converts the given datetime into a UTC SysTime at midnight. Used for storage in databases that don't support a plain date.
SysTime dateAsSysTime(DateTime d) {
	return SysTime(DateTime(d.year, d.month, d.day, 0, 0), UTC());
}

// Converts the given date into a UTC SysTime at midnight. Used for storage in databases that don't support a plain date.
SysTime dateAsSysTime(Date d) {
	return SysTime(DateTime(d), UTC());
}