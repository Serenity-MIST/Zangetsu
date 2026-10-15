-- Run after migrations 0001, 0005, 0007, and the profile cleanup migration
-- on a disposable PostgreSQL DB.
begin;

insert into public.viewer_profiles(user_key, profile_id, name)
values ('00000000-0000-0000-0000-000000000099', 'deleted-profile', 'Test');
insert into public.profile_mylist(user_key, profile_id, source_id, item_id, title)
values ('00000000-0000-0000-0000-000000000099', 'deleted-profile', 'src', 'item', 'Test');

delete from public.viewer_profiles
where user_key = '00000000-0000-0000-0000-000000000099'
  and profile_id = 'deleted-profile';
set constraints viewer_profile_mylist_sync_cleanup immediate;

do $$
begin
  if exists (
    select 1 from public.mylist_sync_clock
    where user_key = '00000000-0000-0000-0000-000000000099'
      and profile_scope = 'deleted-profile'
  ) or exists (
    select 1 from public.mylist_sync_tombstones
    where user_key = '00000000-0000-0000-0000-000000000099'
      and profile_scope = 'deleted-profile'
  ) then
    raise exception 'deleted profile left My List sync state behind';
  end if;
end;
$$;

insert into public.viewer_profiles(user_key, profile_id, name)
values ('00000000-0000-0000-0000-000000000099', 'active-profile', 'Test');
insert into public.profile_mylist(user_key, profile_id, source_id, item_id, title)
values ('00000000-0000-0000-0000-000000000099', 'active-profile', 'src', 'item', 'Test');
delete from public.profile_mylist
where user_key = '00000000-0000-0000-0000-000000000099'
  and profile_id = 'active-profile' and item_id = 'item';

do $$
begin
  if not exists (
    select 1 from public.mylist_sync_tombstones
    where user_key = '00000000-0000-0000-0000-000000000099'
      and profile_scope = 'active-profile' and item_id = 'item'
  ) then
    raise exception 'normal My List delete did not create a tombstone';
  end if;
end;
$$;

insert into public.profile_mylist(user_key, profile_id, source_id, item_id, title)
values ('00000000-0000-0000-0000-000000000099', 'active-profile', 'src', 'item', 'Restored');

do $$
begin
  if exists (
    select 1 from public.mylist_sync_tombstones
    where user_key = '00000000-0000-0000-0000-000000000099'
      and profile_scope = 'active-profile' and item_id = 'item'
  ) then
    raise exception 're-added My List item kept its deletion marker';
  end if;
end;
$$;

rollback;
