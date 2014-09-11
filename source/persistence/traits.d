module persistence.traits;

public import vibe.internal.meta.uda;

// These are from the vibe.d library but are declared privately there.

template Tuple (T...) {
	alias Tuple = T;
}

private template hasAttribute(alias decl, T) { enum hasAttribute = findFirstUDA!(T, decl).found; }

private template hasConvertableFields(T, size_t idx = 0)
{
	static if (idx < __traits(allMembers, T).length) {
		enum mname = __traits(allMembers, T)[idx];
		static if (!isRWPlainField!(T, mname) && !isRWField!(T, mname)) enum hasConvertableFields = hasConvertableFields!(T, idx+1);
		else static if (!hasAttribute!(__traits(getMember, T, mname), ColumnAttribute)) enum hasConvertableFields = hasConvertableFields!(T, idx+1);
		else enum hasConvertableFields = true;
	} else enum hasConvertableFields = false;
}

package template isRWPlainField(T, string M)
{
	static if( !__traits(compiles, typeof(__traits(getMember, T, M))) ){
		enum isRWPlainField = false;
	} else {
		//pragma(msg, T.stringof~"."~M~":"~typeof(__traits(getMember, T, M)).stringof);
		enum isRWPlainField = isRWField!(T, M) && __traits(compiles, *(&__traits(getMember, Tgen!T(), M)) = *(&__traits(getMember, Tgen!T(), M)));
	}
}

package template isRWField(T, string M)
{
	enum isRWField = __traits(compiles, __traits(getMember, Tgen!T(), M) = __traits(getMember, Tgen!T(), M));
	//pragma(msg, T.stringof~"."~M~": "~(isRWField?"1":"0"));
}

package T Tgen(T)(){ return T.init; }

