DROP TABLE GroupBills;

CREATE TABLE GroupBills (
    ACCT_NO        VARCHAR(50)    NOT NULL,
    FNAME          VARCHAR(152)   NOT NULL,
    UTILITY        TINYINT        NOT NULL,
    AMOUNT         DECIMAL(10, 2) NOT NULL,
    NUMBER         VARCHAR(50)    NOT NULL,
    STREET         VARCHAR(50)	  NOT NULL,
    SUFFIX         VARCHAR(50)    NULL,
    BALANCE        DECIMAL(10, 2) NULL,
    PREV_BALANCE   DECIMAL(10, 2) NULL,
    CHARGE         DECIMAL(10, 2) NOT NULL,
    DIFF           INT            NOT NULL,
    POST_DATE      DATE           NOT NULL,
    DUE_DATE       DATE           NOT NULL,
    BILL_TO        VARCHAR(257)   NOT NULL,
    UTIL_NAME      VARCHAR(50)    NOT NULL,
    CUR_READ       VARCHAR(10)    NULL,
    READING        VARCHAR(10)    NULL,
    FLAG           VARCHAR(50)    NULL,
    LATE_BALANCE   DECIMAL(10, 2) NULL,
    MESSAGE        VARCHAR(101)   NULL,
);