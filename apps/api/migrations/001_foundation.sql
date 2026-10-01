-- Foundation metadata only. No customer, media or subscription schema yet.
CREATE TABLE foundation_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO foundation_metadata (key, value) VALUES ('schema_stage', 'foundation');
