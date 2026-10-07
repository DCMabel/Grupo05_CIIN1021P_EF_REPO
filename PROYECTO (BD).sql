-- ============================================================================
-- CONSULTA 1: BASE DE DATOS OPERACIONAL Y OBJETOS DE AUTOMATIZACIÓN
-- PROYECTO: DataSalud Perú - DIRESA La Libertad
-- ============================================================================


CREATE DATABASE DIRESA_Nutricional_DW;
GO

USE DIRESA_Nutricional_DW;
GO

-- 1. ESTRUCTURA DE TABLAS OPERACIONALES (DDL)

-- Tabla de Registro Temporal (Staging Area)
CREATE TABLE dbo.Staging_Evaluacion_Nutricional (
    ID_Registro INT NULL,
    DNI_Paciente VARCHAR(20) NULL,
    Edad INT NULL,
    Provincia NVARCHAR(100) NULL,
    Diagnostico_Nutricional NVARCHAR(100) NULL,
    Fecha_Atencion DATE NULL,
    Observacion_Error NVARCHAR(100) NULL
);
GO

-- Tabla Transaccional Depurada
CREATE TABLE dbo.Atencion_Nutricional (
    ID_Registro INT NOT NULL,
    DNI_Paciente VARCHAR(8) NOT NULL,
    Edad INT NOT NULL,
    Provincia NVARCHAR(100) NOT NULL,
    Diagnostico_Nutricional NVARCHAR(100) NOT NULL,
    Fecha_Atencion DATE NOT NULL,
    Estado_Auditoria NVARCHAR(50) NOT NULL DEFAULT 'Válido',
    Fecha_Carga DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_Atencion_Nutricional PRIMARY KEY CLUSTERED (ID_Registro)
);
GO

-- Tabla de Rechazos e Incidencias
CREATE TABLE dbo.Incidencias_Nutricionales (
    ID_Incidencia INT IDENTITY(1,1) NOT NULL,
    ID_Registro INT NULL,
    DNI_Paciente VARCHAR(20) NULL,
    Edad INT NULL,
    Provincia NVARCHAR(100) NULL,
    Diagnostico_Nutricional NVARCHAR(100) NULL,
    Fecha_Atencion DATE NULL,
    Motivo_Rechazo NVARCHAR(255) NOT NULL,
    Fecha_Deteccion DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_Incidencias_Nutricionales PRIMARY KEY CLUSTERED (ID_Incidencia)
);
GO

-- Tabla de Bitácora / Log de Auditoría Operacional
CREATE TABLE dbo.Log_Auditoria_Operaciones (
    ID_Log INT IDENTITY(1,1) NOT NULL,
    Tipo_Operacion VARCHAR(50) NOT NULL,
    Tabla_Afectada VARCHAR(100) NOT NULL,
    ID_Registro_Afectado INT NULL,
    Descripcion NVARCHAR(500) NOT NULL,
    Usuario VARCHAR(100) NOT NULL DEFAULT SYSTEM_USER,
    Fecha_Evento DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_Log_Auditoria_Operaciones PRIMARY KEY CLUSTERED (ID_Log)
);
GO

-- 2. OBJETOS DE AUTOMATIZACIÓN

-- Procedimiento Almacenado 01: Ingesta Masiva y Depuración Transaccional
CREATE OR ALTER PROCEDURE dbo.usp_ProcesarIngestaNutricional
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TotalLeidos INT = 0;
    DECLARE @TotalValidos INT = 0;
    DECLARE @TotalRechazados INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @TotalLeidos = COUNT(*) FROM dbo.Staging_Evaluacion_Nutricional;

        SAVE TRANSACTION Savepoint_ValidacionPrevia;

        INSERT INTO dbo.Incidencias_Nutricionales (
            ID_Registro, DNI_Paciente, Edad, Provincia, Diagnostico_Nutricional, Fecha_Atencion, Motivo_Rechazo
        )
        SELECT 
            ID_Registro, DNI_Paciente, Edad, Provincia, Diagnostico_Nutricional, Fecha_Atencion,
            CASE 
                WHEN DNI_Paciente IS NULL OR LTRIM(RTRIM(DNI_Paciente)) = '' THEN 'DNI Faltante (Valor Nulo)'
                WHEN Provincia IS NULL OR LTRIM(RTRIM(Provincia)) = '' THEN 'Provincia Faltante (Valor Nulo)'
                WHEN Fecha_Atencion IS NULL THEN 'Fecha de Atención No Asignada'
                WHEN Edad NOT BETWEEN 18 AND 59 THEN 'Edad fuera de rango normativo (18-59)'
                ELSE Observacion_Error
            END AS Motivo_Rechazo
        FROM dbo.Staging_Evaluacion_Nutricional
        WHERE Observacion_Error <> 'OK'
           OR DNI_Paciente IS NULL
           OR Provincia IS NULL
           OR Fecha_Atencion IS NULL
           OR Edad NOT BETWEEN 18 AND 59;

        SET @TotalRechazados = @@ROWCOUNT;

        INSERT INTO dbo.Atencion_Nutricional (
            ID_Registro, DNI_Paciente, Edad, Provincia, Diagnostico_Nutricional, Fecha_Atencion
        )
        SELECT 
            ID_Registro, DNI_Paciente, Edad, Provincia, Diagnostico_Nutricional, Fecha_Atencion
        FROM dbo.Staging_Evaluacion_Nutricional
        WHERE Observacion_Error = 'OK'
          AND DNI_Paciente IS NOT NULL
          AND Provincia IS NOT NULL
          AND Fecha_Atencion IS NOT NULL
          AND (Edad BETWEEN 18 AND 59);

        SET @TotalValidos = @@ROWCOUNT;

        INSERT INTO dbo.Log_Auditoria_Operaciones (Tipo_Operacion, Tabla_Afectada, Descripcion)
        VALUES (
            'ETL_INGESTA',
            'Atencion_Nutricional',
            CONCAT('Lote procesado: Total=', @TotalLeidos, ' | Válidos cargados=', @TotalValidos, ' | Rechazados aislados=', @TotalRechazados)
        );

        COMMIT TRANSACTION;
        PRINT 'Proceso de ingesta y depuración completado exitosamente.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.Log_Auditoria_Operaciones (Tipo_Operacion, Tabla_Afectada, Descripcion)
        VALUES (
            'ERROR_INGESTA',
            'Staging_Evaluacion_Nutricional',
            CONCAT('Error Nro ', ERROR_NUMBER(), ': ', ERROR_MESSAGE())
        );

        THROW;
    END CATCH
END;
GO

-- Procedimiento Almacenado 02: Inserción Individual Síncrona
CREATE OR ALTER PROCEDURE dbo.usp_RegistrarAtencionIndividual
    @p_ID_Registro INT,
    @p_DNI_Paciente VARCHAR(8),
    @p_Edad INT,
    @p_Provincia NVARCHAR(100),
    @p_Diagnostico NVARCHAR(100),
    @p_Fecha_Atencion DATE
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        IF @p_Edad NOT BETWEEN 18 AND 59
            THROW 50001, 'La edad debe estar comprendida en el rango normativo de 18 a 59 años.', 1;

        IF @p_DNI_Paciente IS NULL OR LEN(LTRIM(RTRIM(@p_DNI_Paciente))) <> 8
            THROW 50002, 'El DNI del paciente debe contener exactamente 8 dígitos.', 1;

        INSERT INTO dbo.Atencion_Nutricional (
            ID_Registro, DNI_Paciente, Edad, Provincia, Diagnostico_Nutricional, Fecha_Atencion
        )
        VALUES (
            @p_ID_Registro, @p_DNI_Paciente, @p_Edad, @p_Provincia, @p_Diagnostico, @p_Fecha_Atencion
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.Log_Auditoria_Operaciones (Tipo_Operacion, Tabla_Afectada, ID_Registro_Afectado, Descripcion)
        VALUES (
            'ERROR_INSERT_INDIVIDUAL',
            'Atencion_Nutricional',
            @p_ID_Registro,
            CONCAT('Fallo en inserción: ', ERROR_MESSAGE())
        );

        THROW;
    END CATCH
END;
GO

-- Trigger DML: Auditoría de Cambios e Historiales
CREATE OR ALTER TRIGGER dbo.trg_Auditoria_AtencionNutricional
ON dbo.Atencion_Nutricional
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT * FROM inserted) AND EXISTS (SELECT * FROM deleted)
    BEGIN
        INSERT INTO dbo.Log_Auditoria_Operaciones (Tipo_Operacion, Tabla_Afectada, ID_Registro_Afectado, Descripcion)
        SELECT 
            'UPDATE', 'Atencion_Nutricional', i.ID_Registro,
            CONCAT('Registro actualizado. DNI anterior: ', d.DNI_Paciente, ' -> Nuevo: ', i.DNI_Paciente, 
                   ' | Dx anterior: ', d.Diagnostico_Nutricional, ' -> Nuevo: ', i.Diagnostico_Nutricional)
        FROM inserted i
        INNER JOIN deleted d ON i.ID_Registro = d.ID_Registro;
    END

    IF NOT EXISTS (SELECT * FROM inserted) AND EXISTS (SELECT * FROM deleted)
    BEGIN
        INSERT INTO dbo.Log_Auditoria_Operaciones (Tipo_Operacion, Tabla_Afectada, ID_Registro_Afectado, Descripcion)
        SELECT 
            'DELETE', 'Atencion_Nutricional', d.ID_Registro,
            CONCAT('Registro eliminado. DNI: ', d.DNI_Paciente, ' | Provincia: ', d.Provincia)
        FROM deleted d;
    END
END;
GO

-- Trigger de Integridad: Validación Territorial de La Libertad
CREATE OR ALTER TRIGGER dbo.trg_ValidarProvincia_AtencionNutricional
ON dbo.Atencion_Nutricional
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1 FROM inserted 
        WHERE Provincia NOT IN ('Trujillo', 'Ascope', 'Chepén', 'Pacasmayo', 'Pataz', 'Sánchez Carrión', 'Virú', 'Gran Chimú')
    )
    BEGIN
        INSERT INTO dbo.Log_Auditoria_Operaciones (Tipo_Operacion, Tabla_Afectada, Descripcion)
        SELECT 
            'VIOLACION_INTEGRIDAD', 'Atencion_Nutricional',
            CONCAT('Intento de inserción con provincia no autorizada: ', Provincia)
        FROM inserted
        WHERE Provincia NOT IN ('Trujillo', 'Ascope', 'Chepén', 'Pacasmayo', 'Pataz', 'Sánchez Carrión', 'Virú', 'Gran Chimú');

        RAISERROR('Operación cancelada: La provincia no pertenece a la demarcación oficial de DIRESA La Libertad.', 16, 1);
        ROLLBACK TRANSACTION;
        RETURN;
    END
END;
GO

-- Función Escalar: Clasificación de Riesgo Nutricional
CREATE OR ALTER FUNCTION dbo.fn_ClasificarRiesgoNutricional (
    @Diagnostico NVARCHAR(100)
)
RETURNS VARCHAR(30)
AS
BEGIN
    DECLARE @NivelRiesgo VARCHAR(30);

    SET @NivelRiesgo = CASE 
        WHEN @Diagnostico = 'Normal' THEN 'Bajo Riesgo'
        WHEN @Diagnostico = 'Sobrepeso' THEN 'Riesgo Moderado'
        WHEN @Diagnostico = 'Obesidad Tipo I' THEN 'Riesgo Alto'
        WHEN @Diagnostico = 'Obesidad Tipo II' THEN 'Riesgo Muy Alto'
        WHEN @Diagnostico IN ('Obesidad Mórbida', 'Obesidad Tipo III') THEN 'Riesgo Crítico'
        ELSE 'No Clasificado'
    END;

    RETURN @NivelRiesgo;
END;
GO

-- Función Tabular: Reporte por Provincia
CREATE OR ALTER FUNCTION dbo.fn_ReporteNutricionalPorProvincia (
    @ProvinciaFiltro NVARCHAR(100) = NULL
)
RETURNS TABLE
AS
RETURN (
    SELECT 
        Provincia, Diagnostico_Nutricional,
        dbo.fn_ClasificarRiesgoNutricional(Diagnostico_Nutricional) AS Nivel_Riesgo,
        COUNT(*) AS Total_Atenciones,
        MIN(Fecha_Atencion) AS Primera_Atencion,
        MAX(Fecha_Atencion) AS Ultima_Atencion
    FROM dbo.Atencion_Nutricional
    WHERE (@ProvinciaFiltro IS NULL OR Provincia = @ProvinciaFiltro)
    GROUP BY Provincia, Diagnostico_Nutricional
);
GO

-- 3. SEGURIDAD Y CUMPLIMIENTO (ROLES Y PERMISOS)
CREATE ROLE Rol_Administrador;
CREATE ROLE Rol_AnalistaDatos;
CREATE ROLE Rol_Auditor;
GO

-- Rol Administrador
ALTER ROLE db_owner ADD MEMBER Rol_Administrador;
GO

-- Rol Analista de Datos (Corregido: SELECT para la función de tabla)
GRANT SELECT ON dbo.Atencion_Nutricional TO Rol_AnalistaDatos;
GRANT SELECT ON dbo.fn_ReporteNutricionalPorProvincia TO Rol_AnalistaDatos;
GRANT EXECUTE ON dbo.fn_ClasificarRiesgoNutricional TO Rol_AnalistaDatos;
DENY DELETE, UPDATE, INSERT ON dbo.Atencion_Nutricional TO Rol_AnalistaDatos;
GO

-- Rol Auditor
GRANT SELECT ON dbo.Log_Auditoria_Operaciones TO Rol_Auditor;
GRANT SELECT ON dbo.Incidencias_Nutricionales TO Rol_Auditor;
DENY SELECT ON dbo.Atencion_Nutricional TO Rol_Auditor; 
GO

-- Índice de rendimiento
CREATE NONCLUSTERED INDEX IX_AtencionNutricional_Provincia_Diagnostico
ON dbo.Atencion_Nutricional (Provincia, Diagnostico_Nutricional);
GO

select*from
