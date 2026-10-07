-- ============================================================================
-- CONSULTA 2: DATA WAREHOUSE KIMBALL Y PROCESO ETL
-- PROYECTO: DataSalud Perú - DIRESA La Libertad
-- ============================================================================


CREATE DATABASE DW_DIRESA_Nutricional;
GO

USE DW_DIRESA_Nutricional;
GO

-- 1. MODELO DIMENSIONAL (DDL)

-- Dimensión Paciente
CREATE TABLE dbo.Dim_Paciente (
    ID_Paciente INT IDENTITY(1,1) NOT NULL,
    DNI_Paciente VARCHAR(8) NOT NULL,
    Edad INT NOT NULL,
    Grupo_Etario VARCHAR(30) NOT NULL,
    CONSTRAINT PK_Dim_Paciente PRIMARY KEY CLUSTERED (ID_Paciente)
);
GO

-- Dimensión Ubicación
CREATE TABLE dbo.Dim_Ubicacion (
    ID_Ubicacion INT IDENTITY(1,1) NOT NULL,
    Provincia NVARCHAR(100) NOT NULL,
    Region NVARCHAR(100) NOT NULL DEFAULT 'La Libertad',
    CONSTRAINT PK_Dim_Ubicacion PRIMARY KEY CLUSTERED (ID_Ubicacion)
);
GO

-- Dimensión Tiempo
CREATE TABLE dbo.Dim_Tiempo (
    ID_Tiempo INT NOT NULL, -- Formato YYYYMMDD
    Fecha DATE NOT NULL,
    Anio INT NOT NULL,
    Mes INT NOT NULL,
    Nombre_Mes VARCHAR(20) NOT NULL,
    Trimestre INT NOT NULL,
    CONSTRAINT PK_Dim_Tiempo PRIMARY KEY CLUSTERED (ID_Tiempo)
);
GO

-- Tabla de Hechos con FK Explícitas y Nombradas
CREATE TABLE dbo.Fact_Atencion_Nutricional (
    ID_Atencion INT IDENTITY(1,1) NOT NULL,
    ID_Paciente INT NOT NULL,
    ID_Ubicacion INT NOT NULL,
    ID_Tiempo INT NOT NULL,
    Diagnostico_Nutricional NVARCHAR(100) NOT NULL,
    Nivel_Riesgo VARCHAR(30) NOT NULL,
    Cantidad_Atenciones INT NOT NULL DEFAULT 1,
    Fecha_Carga_DW DATETIME NOT NULL DEFAULT GETDATE(),
    
    CONSTRAINT PK_Fact_Atencion_Nutricional PRIMARY KEY CLUSTERED (ID_Atencion),
    CONSTRAINT FK_Fact_Paciente FOREIGN KEY (ID_Paciente) REFERENCES dbo.Dim_Paciente (ID_Paciente),
    CONSTRAINT FK_Fact_Ubicacion FOREIGN KEY (ID_Ubicacion) REFERENCES dbo.Dim_Ubicacion (ID_Ubicacion),
    CONSTRAINT FK_Fact_Tiempo FOREIGN KEY (ID_Tiempo) REFERENCES dbo.Dim_Tiempo (ID_Tiempo)
);
GO

-- 2. PROCESO ETL INCREMENTAL (Estrategia Kimball)

-- Carga Dim_Ubicacion
INSERT INTO dbo.Dim_Ubicacion (Provincia)
SELECT DISTINCT Provincia 
FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional A
WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Ubicacion U WHERE U.Provincia = A.Provincia);

-- Carga Dim_Paciente
INSERT INTO dbo.Dim_Paciente (DNI_Paciente, Edad, Grupo_Etario)
SELECT DISTINCT 
    DNI_Paciente, Edad,
    CASE 
        WHEN Edad BETWEEN 18 AND 29 THEN 'Joven (18-29)'
        WHEN Edad BETWEEN 30 AND 49 THEN 'Adulto (30-49)'
        ELSE 'Adulto Mayor (50-59)'
    END AS Grupo_Etario
FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional A
WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Paciente P WHERE P.DNI_Paciente = A.DNI_Paciente);

-- Carga Dim_Tiempo
INSERT INTO dbo.Dim_Tiempo (ID_Tiempo, Fecha, Anio, Mes, Nombre_Mes, Trimestre)
SELECT DISTINCT
    CAST(CONVERT(VARCHAR(8), Fecha_Atencion, 112) AS INT) AS ID_Tiempo,
    Fecha_Atencion, YEAR(Fecha_Atencion), MONTH(Fecha_Atencion),
    DATENAME(MONTH, Fecha_Atencion), DATEPART(QUARTER, Fecha_Atencion)
FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional A
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Dim_Tiempo T 
    WHERE T.ID_Tiempo = CAST(CONVERT(VARCHAR(8), A.Fecha_Atencion, 112) AS INT)
);

-- Carga Fact_Atencion_Nutricional
INSERT INTO dbo.Fact_Atencion_Nutricional (
    ID_Paciente, ID_Ubicacion, ID_Tiempo, 
    Diagnostico_Nutricional, Nivel_Riesgo, Cantidad_Atenciones
)
SELECT 
    P.ID_Paciente, U.ID_Ubicacion,
    CAST(CONVERT(VARCHAR(8), A.Fecha_Atencion, 112) AS INT) AS ID_Tiempo,
    A.Diagnostico_Nutricional,
    DIRESA_Nutricional_DW.dbo.fn_ClasificarRiesgoNutricional(A.Diagnostico_Nutricional), 1
FROM DIRESA_Nutricional_DW.dbo.Atencion_Nutricional A
INNER JOIN dbo.Dim_Paciente P ON A.DNI_Paciente = P.DNI_Paciente
INNER JOIN dbo.Dim_Ubicacion U ON A.Provincia = U.Provincia;
GO

-- 3. VERIFICACIÓN FINAL DE DATOS EN EL DATA WAREHOUSE
SELECT * FROM DW_DIRESA_Nutricional.dbo.Fact_Atencion_Nutricional;

-- ============================================================================
--  ZONA DE STAGING Y CONTROL DE ERRORES (Agregado del Diagrama 1)
-- ============================================================================

CREATE TABLE dbo.Staging_Evaluacion_Nutricional (
    ID_Registro INT NULL, -- Permitimos nulos temporalmente
    DNI_Paciente VARCHAR(50) NULL, -- Más espacio por si acaso
    Edad INT NULL,
    Provincia NVARCHAR(150) NULL,
    Diagnostico_Nutricional NVARCHAR(250) NULL,
    Fecha_Atencion DATE NULL,
    Observacion_Error VARCHAR(250) NULL
);
GO

CREATE TABLE dbo.Incidencias_Nutricionales (
    ID_Incidencia INT IDENTITY(1,1) NOT NULL,
    ID_Registro INT NOT NULL,
    DNI_Paciente VARCHAR(8) NULL,
    Edad INT NULL,
    Provincia NVARCHAR(100) NULL,
    Diagnostico_Nutricional NVARCHAR(100) NULL,
    Fecha_Atencion DATE NULL,
    Motivo_Rechazo VARCHAR(250) NOT NULL,
    Fecha_Deccion DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_Incidencias_Nutricionales PRIMARY KEY CLUSTERED (ID_Incidencia)
);
GO


SELECT * FROM DW_DIRESA_Nutricional.dbo.Fact_Atencion_Nutricional;


