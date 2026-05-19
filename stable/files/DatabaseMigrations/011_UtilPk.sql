BEGIN TRAN;

-- 1. Add a new identity column
ALTER TABLE Utilities 
ADD UTIL_PK_new INT IDENTITY(1,1);

-- 2. Drop the old UTIL_PK column
ALTER TABLE Utilities 
DROP COLUMN UTIL_PK;

-- 3. Rename the new identity column to UTIL_PK
EXEC sp_rename 'Utilities.UTIL_PK_new', 'UTIL_PK', 'COLUMN';

-- 4. Add primary key constraint
ALTER TABLE Utilities
ADD CONSTRAINT PK_Utilities PRIMARY KEY (UTIL_PK);

COMMIT TRAN;