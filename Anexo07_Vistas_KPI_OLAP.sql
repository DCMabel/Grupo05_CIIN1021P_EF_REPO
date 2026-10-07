-- ============================================================================
-- PROYECTO : DataSalud Perú - DIRESA La Libertad (Grupo 05)
-- ARCHIVO  : Anexo 07 - Vistas de KPIs, operaciones OLAP y gobernanza
-- MOTOR    : SQL Server 2019+
-- REQUISITO: Haber ejecutado el DDL del DW (Anexo 05) y el ETL (Anexo 06)
--            con los 900 registros válidos cargados.
-- ============================================================================

USE DW_DIRESA_Nutricional;
GO

-- ----------------------------------------------------------------------------
-- 0. VERIFICACIÓN PREVIA: ¿el DW tiene datos suficientes?
--    Esperado: Fact = 900 filas, Dim_Ubicacion = 8 provincias.
-- ----------------------------------------------------------------------------
SELECT 'Fact_Atencion_Nutricional' AS Tabla, COUNT(*) AS Filas FROM dbo.Fact_Atencion_Nutricional
UNION ALL SELECT 'Dim_Paciente',  COUNT(*) FROM dbo.Dim_Paciente
UNION ALL SELECT 'Dim_Ubicacion', COUNT(*) FROM dbo.Dim_Ubicacion
UNION ALL SELECT 'Dim_Tiempo',    COUNT(*) FROM dbo.Dim_Tiempo;

SELECT Diagnostico_Nutricional, Nivel_Riesgo, COUNT(*) AS Total
FROM dbo.Fact_Atencion_Nutricional
GROUP BY Diagnostico_Nutricional, Nivel_Riesgo
ORDER BY Total DESC;
GO

-- ============================================================================
-- 1. VISTAS DE KPIs (fórmula oficial de cada indicador)
--    Regla de "exceso de peso": Sobrepeso o cualquier tipo de Obesidad.
--    Se usa LIKE 'Obesidad%' para no depender de tildes ni subtipos.
-- ============================================================================

-- KPI-01: % de exceso de peso por provincia (Pregunta P1)
CREATE OR ALTER VIEW dbo.vw_KPI_ExcesoPeso_Provincia
AS
SELECT
    U.Provincia,
    COUNT(*) AS Total_Atenciones,
    SUM(CASE WHEN F.Diagnostico_Nutricional = 'Sobrepeso'
               OR F.Diagnostico_Nutricional LIKE 'Obesidad%' THEN 1 ELSE 0 END) AS Atenciones_Exceso_Peso,
    CAST(100.0 * SUM(CASE WHEN F.Diagnostico_Nutricional = 'Sobrepeso'
                            OR F.Diagnostico_Nutricional LIKE 'Obesidad%' THEN 1 ELSE 0 END)
         / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS Pct_Exceso_Peso
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Ubicacion U ON F.ID_Ubicacion = U.ID_Ubicacion
GROUP BY U.Provincia;
GO

-- KPI-02: % de riesgo alto o crítico por grupo etario (Pregunta P2)
CREATE OR ALTER VIEW dbo.vw_KPI_Riesgo_GrupoEtario
AS
SELECT
    P.Grupo_Etario,
    COUNT(*) AS Total_Atenciones,
    SUM(CASE WHEN F.Nivel_Riesgo IN ('Riesgo Alto', 'Riesgo Muy Alto', 'Riesgo Crítico')
             THEN 1 ELSE 0 END) AS Atenciones_Riesgo_Alto,
    CAST(100.0 * SUM(CASE WHEN F.Nivel_Riesgo IN ('Riesgo Alto', 'Riesgo Muy Alto', 'Riesgo Crítico')
                          THEN 1 ELSE 0 END)
         / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS Pct_Riesgo_Alto
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Paciente P ON F.ID_Paciente = P.ID_Paciente
WHERE F.Nivel_Riesgo <> 'No Clasificado'
GROUP BY P.Grupo_Etario;
GO

-- KPI-03: Atenciones por periodo (Pregunta P3)
CREATE OR ALTER VIEW dbo.vw_KPI_Atenciones_Periodo
AS
SELECT
    T.Anio, T.Trimestre, T.Mes, T.Nombre_Mes,
    SUM(F.Cantidad_Atenciones) AS Total_Atenciones
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Tiempo T ON F.ID_Tiempo = T.ID_Tiempo
GROUP BY T.Anio, T.Trimestre, T.Mes, T.Nombre_Mes;
GO

-- KPI-04: Tasa de completitud del lote (Gobernanza)
-- Paso 1: en la BD operacional se crea una vista que SOLO devuelve conteos.
--         Así Power BI obtiene la completitud sin acceso a filas con DNI.
USE DIRESA_Nutricional_DW;
GO
CREATE OR ALTER VIEW dbo.vw_Completitud_Lote
AS
SELECT
    (SELECT COUNT(*) FROM dbo.Atencion_Nutricional)      AS Validos,
    (SELECT COUNT(*) FROM dbo.Incidencias_Nutricionales) AS Incidencias;
GO

-- Paso 2: en el DW, la vista del KPI lee esos conteos.
USE DW_DIRESA_Nutricional;
GO
CREATE OR ALTER VIEW dbo.vw_KPI_Completitud
AS
SELECT
    C.Validos,
    C.Incidencias,
    C.Validos + C.Incidencias AS Recibidos,
    CAST(100.0 * C.Validos / NULLIF(C.Validos + C.Incidencias, 0) AS DECIMAL(5,2)) AS Pct_Completitud
FROM DIRESA_Nutricional_DW.dbo.vw_Completitud_Lote C;
GO

-- Prueba de las vistas (tomar captura de cada resultado para el informe)
SELECT * FROM dbo.vw_KPI_ExcesoPeso_Provincia ORDER BY Pct_Exceso_Peso DESC;
SELECT * FROM dbo.vw_KPI_Riesgo_GrupoEtario    ORDER BY Pct_Riesgo_Alto DESC;
SELECT * FROM dbo.vw_KPI_Atenciones_Periodo    ORDER BY Anio, Mes;
SELECT * FROM dbo.vw_KPI_Completitud;
GO

-- ============================================================================
-- 2. OPERACIONES OLAP (evidencia para la sección 6.4)
-- ============================================================================

-- 2.1 ROLL-UP: de Provincia hasta el total de la Región.
--     Las filas con Provincia = NULL son los subtotales; GROUPING() los rotula.
SELECT
    CASE WHEN GROUPING(U.Region)    = 1 THEN '** TOTAL GENERAL **' ELSE U.Region END AS Region,
    CASE WHEN GROUPING(U.Provincia) = 1 THEN '** Subtotal región **' ELSE U.Provincia END AS Provincia,
    COUNT(*) AS Total_Atenciones
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Ubicacion U ON F.ID_Ubicacion = U.ID_Ubicacion
GROUP BY ROLLUP (U.Region, U.Provincia)
ORDER BY GROUPING(U.Region), U.Region, GROUPING(U.Provincia), U.Provincia;

-- 2.2 DRILL-DOWN: Año -> Trimestre -> Mes (tres niveles de la misma jerarquía)
-- Nivel 1: Año
SELECT T.Anio, COUNT(*) AS Total_Atenciones
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Tiempo T ON F.ID_Tiempo = T.ID_Tiempo
GROUP BY T.Anio ORDER BY T.Anio;

-- Nivel 2: Año + Trimestre
SELECT T.Anio, T.Trimestre, COUNT(*) AS Total_Atenciones
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Tiempo T ON F.ID_Tiempo = T.ID_Tiempo
GROUP BY T.Anio, T.Trimestre ORDER BY T.Anio, T.Trimestre;

-- Nivel 3: Año + Trimestre + Mes
SELECT T.Anio, T.Trimestre, T.Mes, T.Nombre_Mes, COUNT(*) AS Total_Atenciones
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Tiempo T ON F.ID_Tiempo = T.ID_Tiempo
GROUP BY T.Anio, T.Trimestre, T.Mes, T.Nombre_Mes ORDER BY T.Anio, T.Mes;

-- 2.3 SLICE: se fija una sola provincia (Trujillo)
SELECT F.Diagnostico_Nutricional, COUNT(*) AS Total_Atenciones
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Ubicacion U ON F.ID_Ubicacion = U.ID_Ubicacion
WHERE U.Provincia = 'Trujillo'
GROUP BY F.Diagnostico_Nutricional;

-- 2.4 DICE: subcubo de dos provincias x un grupo etario
SELECT U.Provincia, P.Grupo_Etario, F.Nivel_Riesgo, COUNT(*) AS Total_Atenciones
FROM dbo.Fact_Atencion_Nutricional F
INNER JOIN dbo.Dim_Ubicacion U ON F.ID_Ubicacion = U.ID_Ubicacion
INNER JOIN dbo.Dim_Paciente  P ON F.ID_Paciente  = P.ID_Paciente
WHERE U.Provincia IN ('Trujillo', 'Ascope')
  AND P.Grupo_Etario = 'Adulto (30-49)'
GROUP BY U.Provincia, P.Grupo_Etario, F.Nivel_Riesgo;
GO

-- ============================================================================
-- 3. MÉTRICAS DE GOBERNANZA (sección 6.6)
-- ============================================================================

-- 3.1 Consistencia: el DW debe tener exactamente los registros válidos.
SELECT
    (SELECT COUNT(*) FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional) AS Registros_Validos_Origen,
    (SELECT COUNT(*) FROM dbo.Fact_Atencion_Nutricional)                  AS Registros_En_DW,
    CASE WHEN (SELECT COUNT(*) FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional)
            = (SELECT COUNT(*) FROM dbo.Fact_Atencion_Nutricional)
         THEN 'CONSISTENTE' ELSE 'INCONSISTENTE' END AS Resultado;

-- 3.2 Trazabilidad: registros del DW sin origen (esperado: 0 filas)
SELECT F.ID_Registro_Origen
FROM dbo.Fact_Atencion_Nutricional F
WHERE NOT EXISTS (SELECT 1 FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional A
                  WHERE A.ID_Registro = F.ID_Registro_Origen);

-- 3.3 Sesgo (Dilema 2, sección 8.2): incidencias por provincia y motivo.
SELECT
    ISNULL(NULLIF(LTRIM(RTRIM(Provincia)), ''), '(sin provincia)') AS Provincia,
    Motivo_Rechazo,
    COUNT(*) AS Total_Incidencias
FROM DIRESA_Nutricional_DW.dbo.Incidencias_Nutricionales
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(Provincia)), ''), '(sin provincia)'), Motivo_Rechazo
ORDER BY Total_Incidencias DESC;
GO

-- ============================================================================
-- 4. SEGURIDAD ANALÍTICA: usuario de solo lectura para Power BI
--    Los roles son por base de datos; en el DW se crea su propio rol analista.
--    (Requiere autenticación mixta en SQL Server. Si usan Autenticación de
--     Windows en Power BI, pueden omitir el LOGIN y documentarlo.)
-- ============================================================================
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'usr_powerbi')
    CREATE LOGIN usr_powerbi WITH PASSWORD = 'CambiarEstaClave#2026', CHECK_POLICY = ON;
GO
USE DW_DIRESA_Nutricional;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'usr_powerbi')
    CREATE USER usr_powerbi FOR LOGIN usr_powerbi;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'Rol_AnalistaDatos')
    CREATE ROLE Rol_AnalistaDatos;
ALTER ROLE Rol_AnalistaDatos ADD MEMBER usr_powerbi;

GRANT SELECT ON dbo.Fact_Atencion_Nutricional    TO Rol_AnalistaDatos;
GRANT SELECT ON dbo.Dim_Paciente                 TO Rol_AnalistaDatos;
GRANT SELECT ON dbo.Dim_Ubicacion                TO Rol_AnalistaDatos;
GRANT SELECT ON dbo.Dim_Tiempo                   TO Rol_AnalistaDatos;
GRANT SELECT ON dbo.vw_KPI_ExcesoPeso_Provincia  TO Rol_AnalistaDatos;
GRANT SELECT ON dbo.vw_KPI_Riesgo_GrupoEtario    TO Rol_AnalistaDatos;
GRANT SELECT ON dbo.vw_KPI_Atenciones_Periodo    TO Rol_AnalistaDatos;
DENY INSERT, UPDATE, DELETE ON SCHEMA::dbo       TO Rol_AnalistaDatos;
GO
GRANT SELECT ON dbo.vw_KPI_Completitud           TO Rol_AnalistaDatos;
GO

-- usr_powerbi también necesita entrar a la BD operacional, pero SOLO a la
-- vista de conteos (no a las tablas con DNI).
USE DIRESA_Nutricional_DW;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'usr_powerbi')
    CREATE USER usr_powerbi FOR LOGIN usr_powerbi;
GRANT SELECT ON dbo.vw_Completitud_Lote TO usr_powerbi;
GO

-- Prueba de seguridad (captura para el informe): como usr_powerbi,
-- leer la vista funciona y leer la tabla con DNI es rechazado.
EXECUTE AS LOGIN = 'usr_powerbi';
    SELECT * FROM DW_DIRESA_Nutricional.dbo.vw_KPI_Completitud;          -- OK
    BEGIN TRY
        SELECT TOP 1 * FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional; -- Debe fallar
    END TRY
    BEGIN CATCH
        SELECT 'Acceso denegado (esperado): ' + ERROR_MESSAGE() AS Prueba_Seguridad;
    END CATCH
REVERT;
GO
