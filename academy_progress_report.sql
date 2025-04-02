-- Create a materialized table for better performance
DROP TABLE IF EXISTS academy_progress_report;
CREATE TABLE academy_progress_report (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    user_name VARCHAR(255),
    email VARCHAR(255),
    course_id INT NOT NULL,
    course_name VARCHAR(255),
    role VARCHAR(255),
    store VARCHAR(255),
    progress_percentage DECIMAL(5,2) DEFAULT 0.00,
    completed TINYINT(1) DEFAULT 0,
    course_completed_at TIMESTAMP NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    -- Add indexes for faster filtering in Looker
    INDEX idx_user_id (user_id),
    INDEX idx_role (role),
    INDEX idx_store (store),
    INDEX idx_course_id (course_id),
    INDEX idx_completed (completed)
);

-- First, prepare a temporary table with user role information - exclude Administrators and Banyan
DROP TEMPORARY TABLE IF EXISTS user_roles;
CREATE TEMPORARY TABLE user_roles AS
SELECT 
    user_id,
    CASE 
        WHEN meta_value LIKE '%administrator%' THEN 'Administrator'
        WHEN meta_value LIKE '%general_manager%' THEN 'GENERAL MANAGER'
        WHEN meta_value LIKE '%finance_manager%' THEN 'FINANCE MANAGER'
        WHEN meta_value LIKE '%sales_manager_team_leader%' THEN 'SALES MANAGER TEAM LEADER'
        WHEN meta_value LIKE '%bdc_manager%' THEN 'BDC MANAGER'
        WHEN meta_value LIKE '%bdc_team%' THEN 'BDC TEAM'
        WHEN meta_value LIKE '%service_manager%' THEN 'SERVICE MANAGER'
        WHEN meta_value LIKE '%parts_manager%' THEN 'PARTS MANAGER'
        WHEN meta_value LIKE '%advisor%' THEN 'ADVISOR'
        WHEN meta_value LIKE '%technician%' THEN 'TECHNICIAN'
        WHEN meta_value LIKE '%porter%' THEN 'PORTER'
        WHEN meta_value LIKE '%banyan%' THEN 'Banyan'
        WHEN meta_value LIKE '%salesperson%' THEN 'SALESPERSON'
        WHEN meta_value LIKE '%director%' THEN 'Director'
        WHEN meta_value LIKE '%parts%' THEN 'PARTS'
        WHEN meta_value LIKE '%office%' THEN 'OFFICE'
        WHEN meta_value LIKE '%externaltestaccounts%' THEN 'ExternalTestAccounts'
        WHEN meta_value LIKE '%pending%' THEN 'Pending'
        ELSE 'Unknown'
    END AS role
FROM wp_usermeta 
WHERE meta_key = 'wp_capabilities' 
AND meta_value NOT LIKE '%deleted%';

-- Get the Core Certification course ID
DROP TEMPORARY TABLE IF EXISTS core_cert_course;
CREATE TEMPORARY TABLE core_cert_course AS
SELECT ID AS course_id, post_title AS course_name
FROM wp_posts
WHERE post_type = 'sfwd-courses'
AND post_title = 'Core Certification';

-- Get all registered users (excluding admins and banyan)
DROP TEMPORARY TABLE IF EXISTS valid_users;
CREATE TEMPORARY TABLE valid_users AS
SELECT 
    u.ID AS user_id,
    CONCAT(COALESCE(fn.meta_value, ''), ' ', COALESCE(ln.meta_value, '')) AS user_name,
    u.user_email AS email,
    ur.role,
    s.meta_value AS store
FROM wp_users u
JOIN user_roles ur ON u.ID = ur.user_id
LEFT JOIN wp_usermeta fn ON u.ID = fn.user_id AND fn.meta_key = 'first_name'
LEFT JOIN wp_usermeta ln ON u.ID = ln.user_id AND ln.meta_key = 'last_name'
LEFT JOIN wp_usermeta s ON u.ID = s.user_id AND s.meta_key = 'store_name_1'
WHERE ur.role NOT IN ('Administrator', 'Banyan');

-- Get the total count of course items (lessons, topics, quizzes) for each course
DROP TEMPORARY TABLE IF EXISTS course_items;
CREATE TEMPORARY TABLE course_items AS
SELECT 
    course_id,
    COUNT(DISTINCT activity_id) AS total_items
FROM wp_learndash_user_activity
WHERE activity_type IN ('lesson', 'topic', 'quiz')
GROUP BY course_id;

-- Get enrolled users and courses
DROP TEMPORARY TABLE IF EXISTS enrolled_users;
CREATE TEMPORARY TABLE enrolled_users AS
SELECT DISTINCT user_id, course_id
FROM wp_learndash_user_activity
WHERE activity_type IN ('course', 'lesson', 'topic', 'quiz');

-- Get the count of completed items per user and course
DROP TEMPORARY TABLE IF EXISTS user_completions;
CREATE TEMPORARY TABLE user_completions AS
SELECT 
    user_id,
    course_id,
    COUNT(DISTINCT CASE WHEN activity_type IN ('lesson', 'topic', 'quiz') AND activity_completed > 0 
           THEN activity_id ELSE NULL END) AS completed_items,
    MAX(CASE WHEN activity_type = 'course' AND activity_completed > 0 THEN 1 ELSE 0 END) AS course_completed,
    MAX(CASE WHEN activity_type = 'course' AND activity_completed > 0 
        THEN FROM_UNIXTIME(activity_completed) ELSE NULL END) AS course_completed_at
FROM wp_learndash_user_activity
GROUP BY user_id, course_id;

-- Step 1: Insert data for users enrolled in courses (regular enrollments)
INSERT INTO academy_progress_report (user_id, user_name, email, course_id, course_name, role, store, progress_percentage, completed, course_completed_at)
SELECT 
    vu.user_id,
    vu.user_name,
    vu.email,
    c.ID AS course_id,
    c.post_title AS course_name,
    vu.role,
    vu.store,
    CASE
        WHEN uc.course_completed = 1 THEN 1.00
        WHEN ci.total_items > 0 AND uc.completed_items IS NOT NULL THEN 
            LEAST(ROUND(uc.completed_items * 1.0 / ci.total_items, 2), 1.00)  -- Cap at 1.00 (100%)
        ELSE 0.00
    END AS progress_percentage,
    COALESCE(uc.course_completed, 0) AS completed,
    uc.course_completed_at
FROM valid_users vu
JOIN enrolled_users eu ON vu.user_id = eu.user_id
JOIN wp_posts c ON c.ID = eu.course_id AND c.post_type = 'sfwd-courses'
LEFT JOIN course_items ci ON c.ID = ci.course_id
LEFT JOIN user_completions uc ON vu.user_id = uc.user_id AND c.ID = uc.course_id;

-- Step 2: Insert Core Certification course for all users who don't already have it
INSERT INTO academy_progress_report (user_id, user_name, email, course_id, course_name, role, store, progress_percentage, completed, course_completed_at)
SELECT 
    vu.user_id,
    vu.user_name,
    vu.email,
    cc.course_id,
    cc.course_name,
    vu.role,
    vu.store,
    CASE
        WHEN uc.course_completed = 1 THEN 1.00
        WHEN ci.total_items > 0 AND uc.completed_items IS NOT NULL THEN 
            LEAST(ROUND(uc.completed_items * 1.0 / ci.total_items, 2), 1.00)
        ELSE 0.00
    END AS progress_percentage,
    COALESCE(uc.course_completed, 0) AS completed,
    uc.course_completed_at
FROM valid_users vu
CROSS JOIN core_cert_course cc
LEFT JOIN course_items ci ON cc.course_id = ci.course_id
LEFT JOIN user_completions uc ON vu.user_id = uc.user_id AND cc.course_id = uc.course_id
WHERE NOT EXISTS (
    SELECT 1 FROM academy_progress_report apr 
    WHERE apr.user_id = vu.user_id AND apr.course_id = cc.course_id
);

-- Create a view for simpler querying if needed
CREATE OR REPLACE VIEW vw_academy_progress AS
SELECT * FROM academy_progress_report;
