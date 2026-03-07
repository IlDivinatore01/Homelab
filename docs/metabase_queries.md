# 📊 Metabase SQL Queries per Firefly III

## Come creare una Query SQL in Metabase

1. Vai su https://analytics.simonemiglio.eu
2. `+ New` → `SQL Query` → Seleziona `Firefly III`
3. Incolla la query → `Run` (Ctrl+Enter)
4. Scegli visualizzazione → `Save`

---

## ⚠️ Esclusioni e Conversioni

**Categorie escluse dalle spese:**
- `Rimborso`, `Giroconto`, `Crediti amici`, `Split Ele`

**Descrizioni escluse:** `Acquisto ETF`

**Conversione valute:** Solo transazioni in EUR o con conversione EUR vengono contate

---

## 1️⃣ Spese Mensili per Categoria

```sql
SELECT 
    c.name AS Categoria,
    DATE_FORMAT(tj.date, '%Y-%m') AS Mese,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Totale_EUR
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
  AND tj.description NOT LIKE '%Acquisto ETF%'
  AND c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele')
GROUP BY c.name, DATE_FORMAT(tj.date, '%Y-%m')
ORDER BY Mese DESC, Totale_EUR DESC;
```

---

## 2️⃣ Totale Spese per Categoria

```sql
SELECT 
    c.name AS Categoria,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Totale_EUR,
    COUNT(*) AS Num_Transazioni
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
  AND tj.description NOT LIKE '%Acquisto ETF%'
  AND c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele')
GROUP BY c.name
ORDER BY Totale_EUR DESC;
```

---

## 3️⃣ Trend Entrate vs Uscite Mensili

```sql
SELECT 
    DATE_FORMAT(tj.date, '%Y-%m') AS Mese,
    SUM(CASE WHEN tt.type = 'Deposit' AND t.amount > 0
        THEN CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END ELSE 0 END) AS Entrate,
    SUM(CASE WHEN tt.type = 'Withdrawal' AND t.amount < 0 
        AND tj.description NOT LIKE '%Acquisto ETF%'
        AND (c.name IS NULL OR c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele'))
        THEN CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END ELSE 0 END) AS Uscite
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
LEFT JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
LEFT JOIN categories c ON ctj.category_id = c.id
WHERE tt.type IN ('Deposit', 'Withdrawal')
GROUP BY DATE_FORMAT(tj.date, '%Y-%m')
ORDER BY Mese DESC;
```

---

## 4️⃣ Top 10 Destinatari (Dove Spendi)

```sql
SELECT 
    tj.description AS Destinatario,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Totale_EUR,
    COUNT(*) AS Num_Transazioni
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
LEFT JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
LEFT JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
  AND tj.description NOT LIKE '%Acquisto ETF%'
  AND (c.name IS NULL OR c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele'))
GROUP BY tj.description
ORDER BY Totale_EUR DESC
LIMIT 10;
```

---

## 5️⃣ Spese per Giorno Settimana

```sql
SELECT 
    ELT(DAYOFWEEK(tj.date), 'Domenica', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato') AS Giorno,
    DAYOFWEEK(tj.date) AS Giorno_Num,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Totale_EUR
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
LEFT JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
LEFT JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
  AND tj.description NOT LIKE '%Acquisto ETF%'
  AND (c.name IS NULL OR c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele'))
GROUP BY DAYOFWEEK(tj.date)
ORDER BY Giorno_Num;
```

---

## 6️⃣ Bilancio Conti

```sql
SELECT 
    a.name AS Conto,
    at.type AS Tipo,
    ab.balance AS Saldo
FROM accounts a
JOIN account_types at ON a.account_type_id = at.id
JOIN account_balances ab ON a.id = ab.account_id
WHERE a.active = 1
  AND at.type IN ('Asset account', 'Default account')
ORDER BY ab.balance DESC;
```

---

## 7️⃣ Spese Ultimi 30 Giorni

```sql
SELECT 
    c.name AS Categoria,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Totale_EUR
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
  AND tj.date >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
  AND tj.description NOT LIKE '%Acquisto ETF%'
  AND c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele')
GROUP BY c.name
ORDER BY Totale_EUR DESC;
```

---

## 8️⃣ Media Spesa Giornaliera per Mese

```sql
SELECT 
    DATE_FORMAT(tj.date, '%Y-%m') AS Mese,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Totale_EUR,
    COUNT(DISTINCT DATE(tj.date)) AS Giorni,
    ROUND(SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) / COUNT(DISTINCT DATE(tj.date)), 2) AS Media_Giornaliera
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
LEFT JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
LEFT JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
  AND tj.description NOT LIKE '%Acquisto ETF%'
  AND (c.name IS NULL OR c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele'))
GROUP BY DATE_FORMAT(tj.date, '%Y-%m')
ORDER BY Mese DESC;
```

---

## 9️⃣ Transazioni Più Grandi

```sql
SELECT 
    DATE(tj.date) AS Data,
    tj.description AS Descrizione,
    c.name AS Categoria,
    CASE 
        WHEN tc.code = 'EUR' THEN ABS(t.amount)
        WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
        ELSE 0 
    END AS Importo_EUR
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
LEFT JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
LEFT JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
  AND tj.description NOT LIKE '%Acquisto ETF%'
  AND (c.name IS NULL OR c.name NOT IN ('Rimborso', 'Giroconto', 'Crediti amici', 'Split Ele'))
  AND (tc.code = 'EUR' OR fc.code = 'EUR')
ORDER BY Importo_EUR DESC
LIMIT 20;
```

---

## 🔟 Spese per Tag (vacanze, etc.)

```sql
SELECT 
    tg.tag AS Tag,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Totale_EUR,
    COUNT(*) AS Num_Transazioni
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
JOIN tag_transaction_journal ttj ON tj.id = ttj.transaction_journal_id
JOIN tags tg ON ttj.tag_id = tg.id
WHERE tt.type = 'Withdrawal'
  AND t.amount < 0
GROUP BY tg.tag
ORDER BY Totale_EUR DESC
LIMIT 15;
```

---

## 📋 Query Extra Utili

### Stipendi Ricevuti
```sql
SELECT 
    DATE_FORMAT(tj.date, '%Y-%m') AS Mese,
    SUM(
        CASE 
            WHEN tc.code = 'EUR' THEN ABS(t.amount)
            WHEN fc.code = 'EUR' THEN ABS(t.foreign_amount)
            ELSE 0 
        END
    ) AS Stipendio_EUR
FROM transactions t
JOIN transaction_journals tj ON t.transaction_journal_id = tj.id
JOIN transaction_types tt ON tj.transaction_type_id = tt.id
JOIN transaction_currencies tc ON t.transaction_currency_id = tc.id
LEFT JOIN transaction_currencies fc ON t.foreign_currency_id = fc.id
JOIN category_transaction_journal ctj ON tj.id = ctj.transaction_journal_id  
JOIN categories c ON ctj.category_id = c.id
WHERE tt.type = 'Deposit'
  AND c.name = 'Stipendio'
  AND t.amount > 0
GROUP BY DATE_FORMAT(tj.date, '%Y-%m')
ORDER BY Mese DESC;
```
