module persistence.base;

interface ModelInterface {
	@property string idString();
	void setId(string id);
}

struct ModelMeta {
	string containerName;
	string type;
	bool cached;
	bool audit;

	PersistenceAdapter adapter;
}

class PersistenceAdapter {
	protected {
		ModelMeta[string] _meta;
		string _applicationName;
		string _environment;
	}

	this(string name, string environment) {
		_applicationName = name;
		_environment = environment;
	}

	@property string fullName(string name = "") {
		assert(_applicationName.length);
		assert(_environment.length);

		auto returnName = _applicationName ~ "_" ~ _environment;
		if (name.length) returnName ~= "_" ~ name;

		return returnName;
	}

	void registerModel(M)(ModelMeta m) {
		assert(m.containerName.length);
		m.type = M.stringof;
		m.adapter = this;
		_meta[M.stringof] = m;
	}

	@property bool modelRegistered(M)() {
		return (M.stringof in _meta);
	}

	@property ModelMeta modelMeta(M)() {
		return _meta[M.stringof];
	}
}