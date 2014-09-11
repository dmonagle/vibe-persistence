module persistence.base;

interface ModelInterface {
	@property string idString();
	void setId(string id);
	void ensureId();

	bool beforeCreate();
	bool beforeUpdate();
	bool beforeSave();
	void afterSave();
	void afterCreate();
}

class PersistenceModel : ModelInterface {
	bool beforeCreate() { return true; }
	bool beforeUpdate() { return true; }
	bool beforeSave() { return true; }
	void afterSave() {}
	void afterCreate() {}

	abstract @property string idString();
	abstract void setId(string id);
	abstract void ensureId();
}

struct ModelMeta {
	string containerName;
	string type;
	bool cached;
	bool audit;

	PersistenceAdapter adapter;
}

struct EmbeddedAttribute {
}

@property EmbeddedAttribute embedded() { return EmbeddedAttribute(); }

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