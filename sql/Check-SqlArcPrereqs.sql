/*
Run this on each SQL Server instance before Arc onboarding.
It checks database state and the NT AUTHORITY\SYSTEM login requirement used by the Azure extension for SQL Server.
*/

SELECT
    name AS DatabaseName,
    CASE
        WHEN state_desc = 'ONLINE' THEN 'Online'
        WHEN state_desc = 'OFFLINE' THEN 'Offline'
        ELSE state_desc
    END AS Status,
    CASE
        WHEN is_read_only = 0 THEN 'READ_WRITE'
        ELSE 'READ_ONLY'
    END AS UpdateableStatus
FROM sys.databases;

SELECT
    sp.name AS login_name,
    CASE
        WHEN sp.is_disabled = 1 THEN 'DISABLED'
        ELSE 'ENABLED'
    END AS login_status,
    ISNULL(p.state_desc, 'NONE (implicit)') AS connect_sql_permission
FROM sys.server_principals AS sp
LEFT OUTER JOIN sys.server_permissions AS p
    ON p.grantee_principal_id = sp.principal_id
    AND p.permission_name = N'CONNECT SQL'
    AND p.class_desc = N'SERVER'
WHERE sp.name = N'NT AUTHORITY\SYSTEM';
