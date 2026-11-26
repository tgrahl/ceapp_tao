-- List all QTI tests in a TAO database with their internal ID (URI), for the command-line export.
-- Usage on the old server: mysql -u <db-user> -p <db-name> < list-tests.sql
SELECT DISTINCT m.subject AS test_uri, l.object AS label
FROM statements m
LEFT JOIN statements l
  ON l.subject = m.subject AND l.predicate = 'http://www.w3.org/2000/01/rdf-schema#label'
WHERE m.predicate = 'http://www.tao.lu/Ontologies/TAOTest.rdf#TestTestModel'
  AND m.object = 'http://www.tao.lu/Ontologies/TAOTest.rdf#QtiTestModel'
ORDER BY l.object;
