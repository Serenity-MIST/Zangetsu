-- Foreign-key cascades create My List tombstones after a normal parent-row
-- trigger runs. Clean the deleted profile's sync state at transaction end.
create or replace function public.clear_deleted_profile_mylist_sync_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.mylist_sync_tombstones
  where user_key = old.user_key and profile_scope = old.profile_id;
  delete from public.mylist_sync_clock
  where user_key = old.user_key and profile_scope = old.profile_id;
  return old;
end;
$$;

revoke all on function public.clear_deleted_profile_mylist_sync_state()
from public;

drop trigger if exists viewer_profile_mylist_sync_cleanup
on public.viewer_profiles;
create constraint trigger viewer_profile_mylist_sync_cleanup
after delete on public.viewer_profiles
deferrable initially deferred
for each row execute function public.clear_deleted_profile_mylist_sync_state();

-- Repair orphan markers left by deletes made before this trigger existed.
delete from public.mylist_sync_tombstones t
where t.profile_scope <> '' and not exists (
  select 1 from public.viewer_profiles v
  where v.user_key = t.user_key and v.profile_id = t.profile_scope
);
delete from public.mylist_sync_clock c
where c.profile_scope <> '' and not exists (
  select 1 from public.viewer_profiles v
  where v.user_key = c.user_key and v.profile_id = c.profile_scope
);
