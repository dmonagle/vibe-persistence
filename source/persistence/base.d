module persistence.base;

import vibe.data.serialization;

interface ModelInterface {
	@property string idString();
	void setId(string id);
	void ensureId();
	@property ref PersistenceAdapter persistenceAdapter();

	bool beforeCreate();
	bool beforeUpdate();
	bool beforeSave();
	void afterSave();
	void afterCreate();
}

class PersistenceModel : ModelInterface {
	private {
		static PersistenceAdapter _persistenceAdapter;
	}
	
	@ignore static @property ref PersistenceAdapter persistenceAdapter() { return _persistenceAdapter; }

	abstract @property string idString();
	abstract void setId(string id);
	abstract void ensureId();

	bool beforeCreate() { return true; }
	bool beforeUpdate() { return true; }
	bool beforeSave() { return true; }
	void afterSave() {}
	void afterCreate() {}
}

struct ModelMeta {
	string containerName;
	string type;
	bool cached;
	bool audit;
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
		assert(m.containerName.length, "You must specify a container name for model: " ~ M.stringof);
		m.type = M.stringof;
		_meta[M.stringof] = m;
		M.persistenceAdapter = this;
	}

	@property bool modelRegistered(M)() {
		return cast(bool)(M.stringof in _meta);
	}

	@property ModelMeta modelMeta(M)() {
		assert(modelRegistered!M, "Model " ~ M.stringof ~ " is not registered with EsAdapter");
		return _meta[M.stringof];
	}
}