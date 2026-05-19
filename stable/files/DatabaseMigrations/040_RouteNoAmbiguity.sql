use mdms_prod;

DROP VIEW vRouteSheetData;

DROP INDEX IDX_Utilities_RouteSeqServ ON Utilities;

ALTER TABLE Utilities
DROP COLUMN ROUTE_NO;

ALTER TABLE ArchivedUtilities
DROP COLUMN ROUTE_NO;