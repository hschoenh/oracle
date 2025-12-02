## Create Datapump on Oracle Database
For migration and data analysing it is necessary to create ddl file from an Oracle Database Server.<br>
Login to the CDB/PDB where the Schema should exported<br>

### Login as SYSDBA
For example using the sys user to prepare the environment.
```bash
[oracle@localhost datapump]$ sqlplus sys/sys@PDB1 as sysdba

SQL*Plus: Release 19.0.0.0.0 - Production on Mon Mar 7 08:03:17 2022
Version 19.3.0.0.0

Copyright (c) 1982, 2019, Oracle.  All rights reserved.


Connected to:
Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production
Version 19.3.0.0.0
```
### Prepare the datapump
```bash
SQL> CREATE DIRECTORY DATAPUMP  as '/u02/datapump';
SQL> GRANT read,write ON DIRECTORY DATAPUMP to SYSTEM;
```

### Run datapump
```bash
[Example: Export schema include data]
expdp system/sys@PDB1 CONTENT=metadata_only directory=DATAPUMP SCHEMAS=HR DUMPFILE=export_01_hr.dmp
```
```bash
[Example: Export data structure only] 
expdp system/sys@PDB1 CONTENT=metadata_only directory=DATAPUMP SCHEMAS=HR DUMPFILE=export_01_hr.dmp
```
```bash
[oracle@localhost datapump]$ expdp system/sys@PDB1 CONTENT=metadata_only directory=DATAPUMP SCHEMAS=HR DUMPFILE=export_01_hr.dmp

Export: Release 19.0.0.0.0 - Production on Mon Mar 7 08:29:49 2022
Version 19.3.0.0.0

Copyright (c) 1982, 2019, Oracle and/or its affiliates.  All rights reserved.

Connected to: Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production
Starting "SYSTEM"."SYS_EXPORT_SCHEMA_01":  system/********@PDB1 CONTENT=metadata_only directory=DATAPUMP SCHEMAS=HR DUMPFILE=export_01_hr.dmp 
Processing object type SCHEMA_EXPORT/TABLE/INDEX/STATISTICS/INDEX_STATISTICS
Processing object type SCHEMA_EXPORT/TABLE/STATISTICS/TABLE_STATISTICS
Processing object type SCHEMA_EXPORT/STATISTICS/MARKER
Processing object type SCHEMA_EXPORT/USER
Processing object type SCHEMA_EXPORT/SYSTEM_GRANT
Processing object type SCHEMA_EXPORT/ROLE_GRANT
Processing object type SCHEMA_EXPORT/DEFAULT_ROLE
Processing object type SCHEMA_EXPORT/TABLESPACE_QUOTA
Processing object type SCHEMA_EXPORT/PRE_SCHEMA/PROCACT_SCHEMA
Processing object type SCHEMA_EXPORT/SEQUENCE/SEQUENCE
Processing object type SCHEMA_EXPORT/TABLE/TABLE
Processing object type SCHEMA_EXPORT/TABLE/COMMENT
Processing object type SCHEMA_EXPORT/PROCEDURE/PROCEDURE
Processing object type SCHEMA_EXPORT/PROCEDURE/ALTER_PROCEDURE
Processing object type SCHEMA_EXPORT/VIEW/VIEW
Processing object type SCHEMA_EXPORT/TABLE/INDEX/INDEX
Processing object type SCHEMA_EXPORT/TABLE/CONSTRAINT/CONSTRAINT
Processing object type SCHEMA_EXPORT/TABLE/CONSTRAINT/REF_CONSTRAINT
Processing object type SCHEMA_EXPORT/TABLE/TRIGGER
Master table "SYSTEM"."SYS_EXPORT_SCHEMA_01" successfully loaded/unloaded
******************************************************************************
Dump file set for SYSTEM.SYS_EXPORT_SCHEMA_01 is:
  /u02/datapump/export_01_hr.dmp
Job "SYSTEM"."SYS_EXPORT_SCHEMA_01" successfully completed at Mon Mar 7 08:30:26 2022 elapsed 0 00:00:37
```
### Using par file for export data e.g.
Parfile content e.g. Save the file with the content below as "export_hr.par"
```bash
CONTENT=metadata_only 
DIRECTORY=DATAPUMP 
DUMPFILE=export_01_hr.dmp 
LOGFILE=export_01_hr.log
SCHEMAS=HR 
#TABLES=employees,departments
```
Execute parfiles
```bash
expdp system/sys@PDB1 PARFILE='export_hr.par'
```

### Create DDL using impdp tool
```bash
[Example: Generate DDL from Datapump]
impdp system/sys@PDB1 DIRECTORY=DATAPUMP TRANSFORM=OID:n SQLFILE=export_01_hr.sql DUMPFILE=export_01_hr.dmp
```
```bash
[oracle@localhost datapump]$ impdp system/sys@PDB1 DIRECTORY=DATAPUMP TRANSFORM=OID:n SQLFILE=export_01_hr.sql DUMPFILE=export_01_hr.dmp

Import: Release 19.0.0.0.0 - Production on Mon Mar 7 08:30:31 2022
Version 19.3.0.0.0

Copyright (c) 1982, 2019, Oracle and/or its affiliates.  All rights reserved.

Connected to: Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production
Master table "SYSTEM"."SYS_SQL_FILE_FULL_01" successfully loaded/unloaded
Starting "SYSTEM"."SYS_SQL_FILE_FULL_01":  system/********@PDB1 DIRECTORY=DATAPUMP TRANSFORM=OID:n SQLFILE=export_01_hr.sql DUMPFILE=export_01_hr.dmp 
Processing object type SCHEMA_EXPORT/USER
Processing object type SCHEMA_EXPORT/SYSTEM_GRANT
Processing object type SCHEMA_EXPORT/ROLE_GRANT
Processing object type SCHEMA_EXPORT/DEFAULT_ROLE
Processing object type SCHEMA_EXPORT/TABLESPACE_QUOTA
Processing object type SCHEMA_EXPORT/PRE_SCHEMA/PROCACT_SCHEMA
Processing object type SCHEMA_EXPORT/SEQUENCE/SEQUENCE
Processing object type SCHEMA_EXPORT/TABLE/TABLE
Processing object type SCHEMA_EXPORT/TABLE/COMMENT
Processing object type SCHEMA_EXPORT/PROCEDURE/PROCEDURE
Processing object type SCHEMA_EXPORT/PROCEDURE/ALTER_PROCEDURE
Processing object type SCHEMA_EXPORT/VIEW/VIEW
Processing object type SCHEMA_EXPORT/TABLE/INDEX/INDEX
Processing object type SCHEMA_EXPORT/TABLE/CONSTRAINT/CONSTRAINT
Processing object type SCHEMA_EXPORT/TABLE/INDEX/STATISTICS/INDEX_STATISTICS
Processing object type SCHEMA_EXPORT/TABLE/CONSTRAINT/REF_CONSTRAINT
Processing object type SCHEMA_EXPORT/TABLE/TRIGGER
Processing object type SCHEMA_EXPORT/TABLE/STATISTICS/TABLE_STATISTICS
Processing object type SCHEMA_EXPORT/STATISTICS/MARKER
Job "SYSTEM"."SYS_SQL_FILE_FULL_01" successfully completed at Mon Mar 7 08:30:36 2022 elapsed 0 00:00:03
```
### Using par file for import data into DDL e.g.
Parfile content e.g. Save the file with the content below as "import_ddl_hr.par"
```bash
DIRECTORY=DATAPUMP 
TRANSFORM=OID:n 
SQLFILE=import_ddl_01_hr.sql  
DUMPFILE=export_01_hr.dmp
LOGFILE=import_ddl_01_hr.log
```
Execute parfiles
```bash
impdp system/sys@PDB1 PARFILE='import_ddl_hr.par'
```