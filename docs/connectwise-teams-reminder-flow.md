# ConnectWise Unresponded-Ticket Reminder Flow (Power Automate → Microsoft Teams)

This flow checks ConnectWise Manage every 15 minutes for tickets that have not
received a response from the assigned engineer, and sends a Teams reminder
directly to the ticket owner. Because the check re-runs on a schedule and
re-evaluates every ticket each time, reminders automatically repeat every
15 minutes until a response is registered — no extra looping logic or state
storage is required.

---

## Prerequisites

1. **ConnectWise Manage API credentials**
   - An API Member in ConnectWise (System → Members → API Members) with access
     to the service boards you want to monitor.
   - A **public/private key pair** generated for that API member.
   - A **clientId** registered at https://developer.connectwise.com (required
     header on every API call).
2. **Power Automate Premium license** — the HTTP action used to call the
   ConnectWise REST API is a premium connector.
3. **Microsoft Teams connector** (standard) — engineers must be reachable by
   their ConnectWise `officeEmail`, which should match their Microsoft 365 UPN.
   If the addresses differ, add a mapping table (see "Owner → Teams mapping").

## Authentication header

ConnectWise uses Basic auth with a composite username:

```
Authorization: Basic base64( companyId + "+" + publicKey : privateKey )
clientId: <your-registered-client-id>
Accept: application/json
```

Build the base64 value once in a Compose action, or store the whole header
value in an environment variable / Azure Key Vault.

---

## Flow design

```
Recurrence (every 15 min)
  └─ Compose: cutoff time = utcNow() - 15 minutes
  └─ HTTP: GET unresponded tickets from ConnectWise
  └─ Parse JSON
  └─ Apply to each (ticket)
       └─ HTTP: GET owner member record  → officeEmail
       └─ Teams: Post adaptive card in chat with the engineer
```

### 1. Trigger — Recurrence

- Interval: `15`, Frequency: `Minute`.

### 2. Compose — cutoff timestamp

Expression:

```
addMinutes(utcNow(), -15)
```

ConnectWise condition syntax expects timestamps in square brackets,
e.g. `[2026-06-12T18:00:00Z]`. Format it with:

```
concat('[', formatDateTime(addMinutes(utcNow(), -15), 'yyyy-MM-ddTHH:mm:ssZ'), ']')
```

### 3. HTTP — query tickets awaiting a response

```
GET https://<your-site>/v4_6_release/apis/3.0/service/tickets
```

Query parameters (URL-encode the `conditions` value):

```
conditions=closedFlag = false
  and board/name = "<Your Service Board>"
  and status/name in ("New", "New (email)", "Needs Response")
  and dateEntered < <output of step 2>
pageSize=100
fields=id,summary,dateEntered,owner/id,owner/identifier,status/name,company/name
```

Two ways to define "not responded":

- **Status-based (recommended).** Most service boards move a ticket out of
  "New"/"Needs Response" the moment an engineer adds a note or time entry
  (via workflow rules or board automation). Filtering on those statuses plus
  `dateEntered` older than 15 minutes is one API call and is reliable.
  The reminder stops on its own because a responded ticket no longer matches
  the query.
- **Note-based (alternative).** If your statuses don't reflect responses,
  query candidate tickets first, then for each ticket call
  `GET /service/tickets/{id}/allNotes` and treat the ticket as "responded"
  when any note has a non-null `member` (i.e., written by an internal
  engineer rather than the contact). For "responded since the customer's
  last message", compare the newest member note date against the newest
  contact note date. This costs one extra API call per ticket.

> If a ticket has no owner, `owner` is null. Add a Condition inside the loop
> to skip (or route to a team channel instead) when
> `empty(items('Apply_to_each')?['owner'])` is true.

### 4. Parse JSON

Use a sample response from step 3 to generate the schema. The fields you need:
`id`, `summary`, `dateEntered`, `company.name`, `owner.id`, `owner.identifier`.

### 5. Apply to each ticket

**5a. HTTP — resolve the owner's email**

```
GET https://<your-site>/v4_6_release/apis/3.0/system/members/{owner.id}?fields=officeEmail,firstName
```

(Or pre-load all members once per run before the loop and use a Filter array
action inside the loop — fewer API calls if you have many open tickets.)

**5b. Teams — "Post card in a chat or channel"**

- Post as: **Flow bot**
- Post in: **Chat with Flow bot**
- Recipient: `officeEmail` from 5a

Adaptive card body:

```json
{
  "type": "AdaptiveCard",
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "version": "1.4",
  "body": [
    {
      "type": "TextBlock",
      "text": "⏰ Ticket awaiting your response",
      "weight": "Bolder",
      "size": "Medium"
    },
    {
      "type": "FactSet",
      "facts": [
        { "title": "Ticket", "value": "#@{items('Apply_to_each')?['id']}" },
        { "title": "Summary", "value": "@{items('Apply_to_each')?['summary']}" },
        { "title": "Company", "value": "@{items('Apply_to_each')?['company']?['name']}" },
        { "title": "Created", "value": "@{formatDateTime(items('Apply_to_each')?['dateEntered'], 'g')}" }
      ]
    },
    {
      "type": "TextBlock",
      "text": "This reminder repeats every 15 minutes until a response is logged on the ticket.",
      "isSubtle": true,
      "wrap": true
    }
  ],
  "actions": [
    {
      "type": "Action.OpenUrl",
      "title": "Open ticket",
      "url": "https://<your-site>/v4_6_release/services/system_io/Service/fv_sr100_request.rails?service_recid=@{items('Apply_to_each')?['id']}"
    }
  ]
}
```

---

## How the 15-minute loop terminates

There is intentionally **no stored state**. Each run re-queries ConnectWise:

- Ticket still matches (no response logged / status unchanged) → owner gets
  another reminder.
- Engineer responds → status changes (or a member note now exists) → ticket
  drops out of the query → reminders stop.

## Owner → Teams mapping

If ConnectWise `officeEmail` doesn't match the engineer's Microsoft 365 sign-in
address, keep a small mapping (SharePoint list or an `Object` variable like
`{"jsmith": "john.smith@yourdomain.com"}`) and look up the Teams address by
`owner.identifier` before step 5b.

## Optional enhancements

- **Escalation:** count reminders per ticket in a SharePoint list; after N
  reminders, also post to a team channel or notify the service manager.
- **Business hours:** wrap the query/loop in a Condition on
  `dayOfWeek(utcNow())` and hour so engineers aren't pinged overnight.
- **Error handling:** add a parallel "has failed" branch on the HTTP action
  that posts to an ops channel, and set Retry Policy to exponential.
- **Throttling:** ConnectWise allows ~1,000 requests/min per clientId, but if
  you monitor many boards, prefer the "pre-load members once per run" pattern.
