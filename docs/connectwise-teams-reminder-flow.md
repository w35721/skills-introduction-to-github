# ConnectWise Unresponded-Ticket Reminder Flow (Power Automate → Microsoft Teams)

This flow checks ConnectWise Manage every 15 minutes for tickets that have not
received a response from the assigned engineer, and sends a Teams reminder
directly to the ticket owner. Because the check re-runs on a schedule and
re-evaluates every ticket each time, reminders automatically repeat every
15 minutes until a response is registered — no extra looping logic or state
storage is required.

---

## Choosing an approach (licensing)

Calling the ConnectWise REST API from Power Automate requires the **HTTP
action, which is a premium connector** (and the "When an HTTP request is
received" trigger is premium too, so ConnectWise can't call the flow
directly either). Pick based on what you have:

| | Approach | Cost | Looping behavior |
|---|---|---|---|
| **A** | ConnectWise workflow rule → email → standard Power Automate flow | $0 (standard connectors only) | Escalating reminders at fixed intervals (15/30/45/60 min), not infinite |
| **B** | Azure Logic Apps (Consumption) with the HTTP design below | ~$1–2/month pay-per-run | True every-15-min loop until response |
| **C** | Power Automate Premium with the HTTP design below | Premium per-user license | True every-15-min loop until response |

Options B and C use the identical design described in
[the API-polling design](#option-bc-api-polling-design-logic-apps-or-power-automate-premium) —
in Logic Apps the HTTP action is **built-in** (no premium licensing), and the
Microsoft Teams connector is available there as well. A 15-minute recurrence
is ~3,000 runs/month, which costs pennies on the Consumption plan. The only
prerequisite Logic Apps adds is an Azure subscription.

---

## Option A: No-premium design (correlate ConnectWise notification emails)

ConnectWise already sends a notification email for every ticket event —
including **assignment** and **engineer response**. So Power Automate never
needs to ask ConnectWise anything: it just watches a mailbox, correlates
the two email types by ticket number, and reminds the owner every
15 minutes until the "engineer responded" email for that ticket arrives.
Standard connectors only (Office 365 Outlook, SharePoint, Teams).

### State table

Create a SharePoint list `TicketReminders` with columns:

| Column | Type | Notes |
|---|---|---|
| Title | text | Ticket number |
| OwnerEmail | text | Engineer to remind |
| TicketSummary | text | For the card |
| AssignedAt | date/time | When the assignment email arrived |
| Responded | yes/no | Default No |
| RemindersSent | number | Default 0, for escalation |

### Prerequisite: identifiable emails

Each flow needs to tell the email types apart and extract the ticket
number, so check the ConnectWise email setup (Setup Tables → Email
Templates / the templates on each workflow notification):

- The **assignment** and **engineer response** notifications must have
  distinguishable subjects (e.g. containing "has been assigned" vs.
  "has been updated by"). If they're ambiguous — and especially if a
  *customer* reply produces a similar email to an *engineer* reply — edit
  the templates to add a marker token to the subject. Template edits are
  the only ConnectWise-side change this design needs.
- The ticket number must appear in a fixed position, e.g. `Ticket#12345`.
- Ideally the assignment template includes the owner's email address in
  the body; if it only has a name/identifier, add a mapping step (see
  "Owner → Teams mapping").

Route these notifications (or a copy, via a transport rule) to a dedicated
shared mailbox such as `cw-notifications@yourdomain.com`.

### Flow 1 — register the assignment

1. **Trigger:** *When a new email arrives in a shared mailbox (V3)*,
   subject filter = your assignment marker.
2. **Parse ticket number** from the subject, e.g. for `...Ticket#12345...`:

   ```
   first(split(last(split(triggerOutputs()?['body/subject'], 'Ticket#')), ' '))
   ```

3. **SharePoint — Get items** with filter `Title eq '<ticket#>'`.
4. **Condition:** if a row exists (re-assignment), update it — new
   OwnerEmail, `Responded = No`, `RemindersSent = 0`, refresh AssignedAt.
   Otherwise **Create item** with `AssignedAt = utcNow()`.

### Flow 2 — register the engineer's response

1. **Trigger:** same mailbox, subject filter = your engineer-response
   marker. (Make sure customer replies do *not* match this filter.)
2. Parse the ticket number the same way.
3. **Get items** by ticket number → **Update item:** `Responded = Yes`.
   If no row exists yet (response email beat the assignment email, or the
   engineer answered before the first run), **Create item** with
   `Responded = Yes` so Flow 1's upsert doesn't resurrect it incorrectly —
   have Flow 1 skip rows already marked responded for the same assignment.

### Flow 3 — the 15-minute reminder loop

1. **Trigger:** Recurrence, every 15 minutes.
2. **SharePoint — Get items**, OData filter:

   ```
   Responded eq 0 and AssignedAt lt datetime'@{addMinutes(utcNow(), -15)}'
   ```

3. **Apply to each** row:
   - **Teams — Post card in a chat or channel** (Flow bot → chat with
     `OwnerEmail`), using the adaptive card from the API design below.
   - **Update item:** increment `RemindersSent`.
   - **(Optional escalation)** Condition: if `RemindersSent >= 4`
     (an hour of silence), also post to the service manager or a team
     channel.

Because Flow 3 re-reads the list every run, reminders genuinely repeat
every 15 minutes until Flow 2 flips `Responded` — the true infinite loop,
with no premium connectors. Add a weekly cleanup flow (or extend Flow 2)
to delete responded rows and keep the list small.

### Lighter variant: single long-running flow (no SharePoint)

If you'd rather avoid the list: in Flow 1, after parsing, add a
**Do until** loop — *Delay 15 minutes* → *Get emails (V3)* searching the
mailbox for the response marker + ticket number received after the trigger
time → if found, exit; if not, post the Teams card. Raise the Do until
limits (default is 60 iterations / 1 hour timeout). This works, but one
flow run stays open per ticket for the whole wait, a failed run silently
stops reminding, and there's no audit trail — the state-table design is
more robust for real ticket volume.

### Variant without notification emails: workflow rules

If you'd rather not rely on the notification stream, ConnectWise
**workflow rules** can do the detection instead: a rule on the board with
conditions (status in "New"/"Needs Response", owner set) and events at 15,
30, 45, 60 minutes, each emailing a structured message
(`CW-REMINDER|<ticket#>|<owner email>`) that a single standard flow turns
into the Teams card. Each event fires once per ticket, so this gives a
fixed escalation ladder rather than an infinite loop.

---

## Option B/C: API-polling design (Logic Apps or Power Automate Premium)

## Prerequisites

1. **ConnectWise Manage API credentials**
   - An API Member in ConnectWise (System → Members → API Members) with access
     to the service boards you want to monitor.
   - A **public/private key pair** generated for that API member.
   - A **clientId** registered at https://developer.connectwise.com (required
     header on every API call).
2. **Either** an Azure subscription (Logic Apps Consumption — the HTTP
   action there is built-in, no premium licensing) **or** a Power Automate
   Premium license (the HTTP action in Power Automate is a premium
   connector).
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
