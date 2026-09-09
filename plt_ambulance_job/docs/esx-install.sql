-- plt_ambulance_job - ESX install script
-- Run this once against your server database (e.g. via HeidiSQL / phpMyAdmin).
--
-- 1. Register every item the resource uses in ESX's `items` table.
-- 2. Add the `medical_insurance` column the pharmacy writes to.
-- 3. Create the resource's own tables (boss menu / PCR / X-ray storage).

-- ---------------------------------------------------------------- items --
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_medkit', 'Medkit', 500, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_bandage', 'Bandage', 100, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_painkillers', 'Painkillers', 50, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_antibiotics', 'Antibiotics', 50, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_surgical_kit', 'Surgical Kit', 1000, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_stretcher', 'Stretcher', 5000, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_oxygen_mask', 'Oxygen Mask', 300, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_surgical_scissors', 'Surgical Scissors', 200, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_radio', 'Radio', 200, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_medical_bag', 'Medical Bag', 2000, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_bp_monitor', 'BP Monitor', 500, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_flashlight', 'Flashlight', 500, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_fireextinguisher', 'Fire Extinguisher', 2000, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_prescription', 'Medical Prescription', 50, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_ems_certificate', 'EMS Certificate', 50, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('iak_wheelchair', 'Wheelchair', 5000, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_walking_stick', 'Walking Stick', 800, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_cane', 'Cane', 800, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_crutches', 'Crutches', 1200, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('as_xray_clipboard_01', 'X-Ray Clipboard #01', 200, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('as_xray_clipboard_02', 'X-Ray Clipboard #02', 200, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('as_xray_clipboard_03', 'X-Ray Clipboard #03', 200, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('as_xray_clipboard_04', 'X-Ray Clipboard #04', 200, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('plt_painkillers_adv', 'Advanced Painkillers', 50, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`), `weight` = VALUES(`weight`);

-- ------------------------------------------------- pharmacy insurance --
-- Wrapped in a procedure because MySQL has no ADD COLUMN IF NOT EXISTS.
DROP PROCEDURE IF EXISTS plt_amb_add_insurance;
DELIMITER $$
CREATE PROCEDURE plt_amb_add_insurance()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users'
          AND COLUMN_NAME = 'medical_insurance'
    ) THEN
        ALTER TABLE `users` ADD COLUMN `medical_insurance` VARCHAR(64) NULL DEFAULT NULL;
    END IF;
END $$
DELIMITER ;
CALL plt_amb_add_insurance();
DROP PROCEDURE plt_amb_add_insurance;

-- -------------------------------------------------- resource tables ----
CREATE TABLE IF NOT EXISTS `plt_ambulance_job_data` (
    `key`   VARCHAR(64) NOT NULL,
    `value` LONGTEXT NULL,
    PRIMARY KEY (`key`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE IF NOT EXISTS `plt_ambulance_job_pcrs` (
    `id`       INT NOT NULL AUTO_INCREMENT,
    `patient`  VARCHAR(128) NULL,
    `citizenid` VARCHAR(128) NULL,
    `report`   LONGTEXT NULL,
    `date`     VARCHAR(64) NULL,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE IF NOT EXISTS `plt_ambulance_job_xrays` (
    `id`        INT NOT NULL AUTO_INCREMENT,
    `citizenid` VARCHAR(128) NULL,
    `injuries`  LONGTEXT NULL,
    `date`      VARCHAR(64) NULL,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ------------------------------------------------------- department -----
-- The job must exist in ESX before the script can hand out ranks.
INSERT IGNORE INTO `jobs` (`name`, `label`, `whitelisted`) VALUES ('ambulance', 'Ambulance', 0);
INSERT IGNORE INTO `job_grades` (`job_name`, `grade`, `name`, `label`, `salary`) VALUES
    ('ambulance', 0, 'recruit',    'Recruit',    20),
    ('ambulance', 1, 'paramedic',  'Paramedic',  40),
    ('ambulance', 2, 'doctor',     'Doctor',     60),
    ('ambulance', 3, 'chief',      'Chief',      80),
    ('ambulance', 4, 'boss',       'Director',  100);
